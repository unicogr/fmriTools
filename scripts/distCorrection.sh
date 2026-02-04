#!/bin/bash
# BIDS-compatible distortion correction for 7T data
# Usage: bash distCorrection.sh sub-01 ses-01

# Set subject and session from arguments
subj_number=$1
session=$2

# Load configuration values efficiently using yq
{
read -r user_folder
read -r project_folder
read -r programs_path
read -r func_type
} < <(yq -r '.Paths.user_folder, .Paths.project_folder, .Paths.programs_path, .MRI.functional' conf.yaml)

# Construct output and bids directories
output_folder="${user_folder}${project_folder}/output"
bids_dir="$output_folder"

# Get all task patterns from conf.yaml
task_patterns=()
mapfile -t task_patterns < <(yq -r '.Tasks | to_entries[] | .value' conf.yaml)

echo "Task patterns: ${task_patterns[*]}"

# Automatically detect phase encoding directions from BIDS directory structure
# Look for the first pair of dir-ap and dir-pa files to determine the directions
func_folder="${bids_dir}/${subj_number}/${session}/func"

echo "Detecting phase encoding directions from BIDS directory..."

# Find first bold file with direction encoding
first_bold=$(find "$func_folder" -name "*_bold.nii.gz" -type f | head -1)

if [ -z "$first_bold" ]; then
    echo "ERROR: No BOLD files found in $func_folder"
    exit 1
fi

# Extract direction from filename (dir-ap or dir-pa)
if [[ "$first_bold" =~ _dir-([a-z]+)_ ]]; then
    moving_direction="${BASH_REMATCH[1]}"
    
    # Determine opposite direction
    if [ "$moving_direction" = "ap" ]; then
        static_direction="pa"
    elif [ "$moving_direction" = "pa" ]; then
        static_direction="ap"
    else
        echo "ERROR: Unknown phase encoding direction: $moving_direction"
        exit 1
    fi
else
    echo "ERROR: Could not extract phase encoding direction from filename: $first_bold"
    exit 1
fi

echo "Detected moving direction: $moving_direction"
echo "Detected static direction: $static_direction"


log_and_return() {
    local message="$1"
    local log_file="$2"
    local output_dir="$3"
    
    echo "ERROR: $message"
    echo "Check error log: $log_file"
    if [ -f "$log_file" ]; then
        echo "Last few lines of error log:"
        tail -n 5 "$log_file"
    fi
    
    echo "Cleaning up output directory due to topup failure..."
    rm -rf "$output_dir"
    return 1
}



# Setup tool paths
export FREESURFER_HOME=${programs_path}/freesurfer
source $FREESURFER_HOME/SetUpFreeSurfer.sh

FSLDIR=${programs_path}/fsl
. ${FSLDIR}/etc/fslconf/fsl.sh
PATH=${FSLDIR}/bin:${PATH}
export FSLDIR PATH

export PATH=${programs_path}/ants-2.5.4/bin:$PATH

# BIDS directory structure
func_folder="${bids_dir}/${subj_number}/${session}/func"

stc_dir="${bids_dir}/derivatives/slice-timing-corrected/${subj_number}/${session}/func"

output_dir="${bids_dir}/derivatives/distortion-corrected/${subj_number}/${session}/func"
mkdir -p "$output_dir"

echo "Processing BIDS functional data for ${subj_number}/${session}"
echo "Input directory: $func_folder"
echo "Output directory: $output_dir"
echo "Functional data type: $func_type"

# ==============================================
# Distortion Correction (AP from stc_dir, PA from func_folder)
# ==============================================

for pattern in "${task_patterns[@]}"; do
    # Extract base_name from pattern, same as in dicom2BIDS
    if [[ "$pattern" =~ ^([A-Za-z]+)[^0-9]*([0-9]+)?$ ]]; then
        base_name="${BASH_REMATCH[1]}"
    else
        base_name="$pattern"
    fi
    
    echo "Processing task pattern: $pattern (base_name: $base_name)"
    
    # Find all AP bold files matching the base_name
    mapfile -t ap_files < <(find "$stc_dir" -name "*acq-${base_name}*_desc-stc_bold.nii.gz" -type f | sort)
    
    if [ ${#ap_files[@]} -eq 0 ]; then
        echo "No AP files found for base_name: $base_name"
        continue
    fi
    
    for ap_nifti in "${ap_files[@]}"; do
        ap_base=$(basename "$ap_nifti" _desc-stc_bold.nii.gz)
        
        # Handle double acq- pattern if present
        if [[ $ap_base == *"acq-"*"acq-"* ]]; then
            ap_base=$(echo "$ap_base" | sed 's/acq-\([^_]*\)_acq-/acq-\1_dir-/')
        fi
        
        # Construct PA base by replacing direction and changing suffix dynamically using func_type from conf.yaml
        pa_base="${ap_base/dir-${moving_direction}/dir-${static_direction}}"
        ap_suffix="_${func_type}_bold"
        pa_suffix="_${func_type}"
        pa_base=$(echo "$pa_base" | sed "s/${ap_suffix}/${pa_suffix}/")

        pa_nifti="$func_folder/${pa_base}.nii.gz"
    output_run_dir="$output_dir/$ap_base"

    mkdir -p "$output_run_dir"
    #echo "Processing directory: $output_run_dir"


    # Check if the corrected moving image already exists
    corrected_moving_image="$output_run_dir/${ap_base}_desc-dc_bold.nii.gz"

    preprocess=false
    if [ ! -f "$corrected_moving_image" ]; then
        echo "Applying distortion correction for $ap_base"
        preprocess=true
    fi

    if [ -f "$corrected_moving_image" ]; then
        # Compare file sizes
        size_ap=$(stat -c %s "$ap_nifti")
        size_corr=$(stat -c %s "$corrected_moving_image")
        diff_mb=$(( (size_ap - size_corr) / 1024 / 1024 ))
        if [ $diff_mb -ge 200 ]; then
            echo "Warning: output more than 200 MB smaller than input ($diff_mb MB difference), someting may be wrong."
            preprocess=true
        fi
    fi
    
    if [ "$preprocess" = false ]; then
        echo "Skipping distortion correction for $ap_base, already processed."
        continue
    fi


    if [ "$preprocess" = true ]; then
        echo "Processing: $ap_base"

#    fi
  
#done




         

         # Check if there is an image with odd z-dimension and pad it if necessary
         dim=$(mri_info --dim "$ap_nifti")
         x=$(echo $dim | cut -d" " -f1)
         y=$(echo $dim | cut -d" " -f2)
         z=$(echo $dim | cut -d" " -f3)
         t=$(echo $dim | cut -d" " -f4)
         echo "Dimensions: x=$x, y=$y, z=$z, t=$t"

         if (( z % 2 == 1 )); then

            echo "Odd dimensions!!! ... padding z-dimension by 1"
            # Perform distortion correction here
            ap_image="$output_run_dir/AP_image.nii.gz"
            pa_image="$output_run_dir/PA_image.nii.gz"
            combined_ap_pa="$output_run_dir/combined_AP_PA.nii.gz"


            echo "Padding AP and PA images to even z-dimension..."

            padded_ap_image="$output_run_dir/AP_image_pad.nii.gz"
            padded_pa_image="$output_run_dir/PA_image_pad.nii.gz"
            padded_nifti="$output_run_dir/moving_image_padded.nii.gz"
            

            # Define output and intermediate file paths
            acqparams_file="$output_run_dir/acqparams.txt"
            topup_out="$output_run_dir/topup_results"
            hifi_b0="$output_run_dir/hifi_b0.nii.gz"
            fieldmap="$output_run_dir/fieldmap.nii.gz"

            # Extract the first volume from padded AP and PA images
            fslroi ${ap_nifti} ${ap_image} 0 1
            fslroi ${pa_nifti} ${pa_image} 0 1


            # Pad the AP and PA images along the 3rd dimension
            fslroi ${ap_image} ${padded_ap_image} 0 $x 0 $y 0 $((z + 1))
            fslroi ${pa_image} ${padded_pa_image} 0 $x 0 $y 0 $((z + 1))
            

            # Combine AP and PA images into a single 4D file
            echo "Combining AP and PA images..."
            fslmerge -t ${output_run_dir}/combined_AP_PA.nii.gz ${padded_ap_image} ${padded_pa_image}

            echo "Dimensions in: ${output_run_dir}/combined_AP_PA.nii.gz"
            mri_info --dim ${output_run_dir}/combined_AP_PA.nii.gz


            # Padding the distortion corrected image to match the size of the fieldmap
            fslroi $ap_nifti "$padded_nifti" 0 $x 0 $y 0 $((z + 1)) 0 $t

            echo "Dimensions in: $padded_nifti"
            mri_info --dim $padded_nifti

                        # Run topup
            # Create the acquisition parameters file
            echo "Creating acquisition parameters file: $acqparams_file"
            cat <<EOT > "$acqparams_file"
0 -1 0 0.05
0 1 0 0.05
EOT
        
            # Create log file for this run
            log_file="$output_run_dir/topup_error.log"
            
            echo "Running topup..."
            if ! topup --imain=${output_run_dir}/combined_AP_PA.nii.gz \
                --datain="$acqparams_file" \
                --config=b02b0.cnf \
                --out="$topup_out" \
                --iout="$hifi_b0" \
                --fout="$fieldmap" 2> >(tee -a "$log_file"); then
                
                log_and_return "Topup failed for odd dimensions case: $ap_base" "$log_file" "$output_run_dir"
                break
            fi

            echo "Applying distortion correction..."
            if ! applytopup --imain="$padded_nifti" \
                    --datain="$acqparams_file" \
                    --inindex=1 \
                    --topup="$topup_out" \
                    --out="$corrected_moving_image" \
                    --method=jac 2>> "$log_file"; then
                
                log_and_return "Applytopup failed for odd dimensions case: $ap_base" "$log_file" "$output_run_dir"
                break
            fi

        fi

        ## Normal case
        if (( z % 2 == 0 )); then

            echo "Even dimensions!"
            
            # Perform distortion correction here
            ap_image="$output_run_dir/AP_image.nii.gz"
            pa_image="$output_run_dir/PA_image.nii.gz"
            combined_ap_pa="$output_run_dir/combined_AP_PA.nii.gz"

            # Define output and intermediate file paths
            acqparams_file="$output_run_dir/acqparams.txt"
            topup_out="$output_run_dir/topup_results"
            hifi_b0="$output_run_dir/hifi_b0.nii.gz"
            fieldmap="$output_run_dir/fieldmap.nii.gz"

            # Extract the first volume from padded AP and PA images
            fslroi ${ap_nifti} ${ap_image} 0 1
            fslroi ${pa_nifti} ${pa_image} 0 1

            # Combine AP and PA images into a single 4D file
            echo "Combining AP and PA images..."
            fslmerge -t $output_run_dir/combined_AP_PA.nii.gz "$ap_image" "$pa_image"
            mri_info --dim $output_run_dir/combined_AP_PA.nii.gz



            # Run topup
            # Create the acquisition parameters file
            echo "Creating acquisition parameters file: $acqparams_file"
            cat <<EOT > "$acqparams_file"
0 -1 0 0.05
0 1 0 0.05
EOT
            # Create log file for this run
            log_file="$output_run_dir/topup_error.log"
                    
            echo "Running topup..."
            if ! topup --imain="$output_run_dir/combined_AP_PA.nii.gz" \
                --datain="$acqparams_file" \
                --config=b02b0.cnf \
                --out="$topup_out" \
                --iout="$hifi_b0" \
                --fout="$fieldmap" 2> >(tee -a "$log_file"); then
                
                log_and_return "Topup failed for even dimensions case: $ap_base" "$log_file" "$output_run_dir"
                break
            fi

            echo "Applying distortion correction..."
            if ! applytopup --imain="$ap_nifti" \
                    --datain="$acqparams_file" \
                    --inindex=1 \
                    --topup="$topup_out" \
                    --out="$corrected_moving_image" \
                    --method=jac 2>> "$log_file"; then
                
                log_and_return "Applytopup failed for even dimensions case: $ap_base" "$log_file" "$output_run_dir"
                break
            fi
        fi
    fi

    # Clean up intermediate files
    echo "Cleaning up intermediate files..."
    rm -f "$ap_image" "$pa_image" "$combined_ap_pa"* 
    rm -f "$hifi_b0"*
    rm -f "$fieldmap"*
    rm -f "$topup_out"*
    rm -f "$acqparams_file"

    if (( z % 2 == 1 )); then
        rm -f "$padded_ap_image" "$padded_pa_image" "$padded_nifti"
    fi
    echo "Distortion correction completed for file: $ap_base"
    echo "--------------------------------------------------"

  
done
done