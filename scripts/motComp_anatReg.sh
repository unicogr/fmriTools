#!/bin/bash
#
# Motion Compensation and Anatomical Registration Pipeline for 3T fMRI Data
#
# This script performs a multi-step preprocessing pipeline:
# 1. Motion correction of distortion-corrected BOLD runs using AFNI's 3dvolreg
# 2. Creation of a reference volume from the first run's first timepoint
# 3. Between-run alignment using AFNI's 3dAllineate:
#    - Computes transformation from first volume to reference
#    - Applies same transformation to all volumes (warning about reuse is expected)
#    - Note: The warning "Reusing final row of -1D*_apply" is expected and can be ignored
#      as we intentionally use a single transformation for each run after motion correction
# 4. BBR registration to anatomical space using FreeSurfer's bbregister
# 5. Application of BBR transformation to all aligned runs
#
# Note on oblique datasets:
# - If you receive warnings about oblique datasets, this indicates your data was acquired
#   at an angle to the cardinal axes
# - If all runs were acquired with the same parameters, this warning can be safely ignored
# - Alternatively, you can use 3dWarp -deoblique if cardinal alignment is needed
#
# Input:
# - Distortion-corrected BOLD runs (*_desc-dc_bold.nii.gz)
# - FreeSurfer-processed anatomical data (brain.mgz)
#
# Output:
# - Motion-corrected files (*_desc-mc_bold.nii.gz)
# - Between-run aligned files (*_desc-aligned_bold.nii.gz)
# - Anatomically registered files (*_desc-coreg_bold.nii.gz)
# - Motion parameters and transformation matrices
#
# Usage: 
#     bash motComp_anatReg_3T.sh <subject_id> <session_id>
# Example:
#     bash motComp_anatReg_3T.sh sub-01 ses-01
#
# Dependencies:
# - FSL
# - AFNI
# - FreeSurfer
# - ANTs
#
# author: nicolas.gravel@inserm.fr


# Check if the subject number and session are provided as arguments
if [ $# -lt 2 ]; then
  echo "Warning: No subject and session provided, using defaults"
  subj_number="sub-01"
  session="ses-01"
else
  subj_number="$1"
  session="$2"
fi

# Read variables from conf.yaml
user_folder=$(yq -r '.Paths.user_folder' conf.yaml | sed 's:/*$::')
project_folder=$(yq -r '.Paths.project_folder' conf.yaml | sed 's:/*$::')
programs_path=$(yq -r '.Paths.programs_path' conf.yaml | sed 's:/*$::')
func_type=$(yq -r '.MRI.functional' conf.yaml)

# Get all task patterns from conf.yaml
task_patterns=()
mapfile -t task_patterns < <(yq -r '.Tasks | to_entries[] | .value' conf.yaml)




# Setup tool paths
export FREESURFER_HOME=${programs_path}/freesurfer
source $FREESURFER_HOME/SetUpFreeSurfer.sh
#  Local output for freesurfer 
export SUBJECTS_DIR=${user_folder}/${project_folder}/output/fs_subjects

# ANTs
export PATH=${programs_path}/ants-2.5.4/bin:$PATH


FSLDIR=${programs_path}/fsl
. ${FSLDIR}/etc/fslconf/fsl.sh
PATH=${FSLDIR}/bin:${PATH}
export FSLDIR PATH

# BIDS directory structure
bids_dir="${user_folder}/${project_folder}/output"


dcorr_dir="${bids_dir}/derivatives/distortion-corrected/${subj_number}/${session}/func"


output_dir="${bids_dir}/derivatives/motion-compensated/${subj_number}/${session}/func"
mkdir -p "$output_dir"

echo "Processing BIDS functional data for ${subj_number}/${session}"
echo "Input directory: $dcorr_dir"
echo "Output directory: $output_dir"
echo "Functional data type: $func_type"
echo "Task patterns: ${task_patterns[*]}"

# ==============================================
# Motion compensation 
# ==============================================

echo "Reading task patterns from conf.yaml to determine processing order..."

# Build ordered list of distortion-corrected files based on conf.yaml task order
declare -a dc_niftis_ordered

for pattern in "${task_patterns[@]}"; do
    # Extract base name (e.g., "ML" from "ML-run1")
    if [[ "$pattern" =~ ^([A-Za-z]+)[^0-9]*([0-9]+)?$ ]]; then
        base_name="${BASH_REMATCH[1]}"
    else
        base_name="$pattern"
    fi
    
    # Find all files matching this task pattern, sorted by run number
    mapfile -t matching_files < <(find "$dcorr_dir" -type f \
        -name "*_acq-${base_name}*_desc-dc_bold.nii.gz" | sort)
    
    if [ ${#matching_files[@]} -gt 0 ]; then
        echo "Found ${#matching_files[@]} file(s) for task pattern: $pattern (base: $base_name)"
        dc_niftis_ordered+=("${matching_files[@]}")
    else
        echo "WARNING: No distortion-corrected files found for task pattern: $pattern"
    fi
done

if [ ${#dc_niftis_ordered[@]} -eq 0 ]; then
    echo "ERROR: No matching distortion-corrected files found for any task in conf.yaml"
    exit 1
fi

# Use ordered list
dc_niftis=("${dc_niftis_ordered[@]}")

echo ""
echo "Processing order (${#dc_niftis[@]} runs total):"
for i in "${!dc_niftis[@]}"; do
    if [ $i -eq 0 ]; then
        echo "  $((i+1)): $(basename ${dc_niftis[$i]}) [REFERENCE]"
    else
        echo "  $((i+1)): $(basename ${dc_niftis[$i]})"
    fi
done
echo ""

# Loop through each distortion-corrected file in conf.yaml order
for dc_nifti in "${dc_niftis[@]}"; do
    echo "Processing: $dc_nifti"
    
    # Extract base name for this run
    dc_base=$(basename "$dc_nifti" _desc-dc_bold.nii.gz)
    echo "Base name: $dc_base"
    
    # Create output directory for this run
    output_run_dir="$output_dir/$dc_base"
    mkdir -p "$output_run_dir"
    echo "Processing directory: $output_run_dir"
    
    # Define output file paths
    output_motion_params="$output_run_dir/${dc_base}_motion_params.1D"
    output_affine_matrices="$output_run_dir/${dc_base}_affine_matrix.aff12.1D"
    output_motion_corrected="$output_run_dir/${dc_base}_desc-mc_bold.nii.gz"
    
    # Check if motion correction has already been done
    if [ -f "$output_motion_corrected" ]; then
        echo "Motion corrected file already exists: $output_motion_corrected. Skipping motion correction."
        continue
    fi
    
    # Get the dimensions using mri_info
    dim=$(mri_info --dim "$dc_nifti")
    echo "Dimensions: $dim"
    x=$(echo $dim | cut -d" " -f1)
    y=$(echo $dim | cut -d" " -f2)
    z=$(echo $dim | cut -d" " -f3)
    t=$(echo $dim | cut -d" " -f4)
    
    echo "Performing motion correction for ${dc_nifti}..."
    
    3dvolreg -verbose \
            -base 0 \
            -1Dfile "${output_motion_params}" \
            -1Dmatrix_save "${output_affine_matrices}" \
            -zpad 4 \
            -prefix "${output_motion_corrected}" \
            "${dc_nifti}"
    
    echo "Motion compensation completed for run: $dc_base"
    echo "--------------------------------------------------"
done

echo "Motion compensation completed for all runs."

# =======================================================================
# Get the first volume of the first functional scan and save it as refVol
# =======================================================================

# Use the first run from our conf.yaml-ordered list as reference
ref_dc_nifti="${dc_niftis[0]}"
ref_run_base=$(basename "$ref_dc_nifti" _desc-dc_bold.nii.gz)

echo "Reference run (from conf.yaml task order): $(basename $ref_dc_nifti)"
echo "Reference run base: $ref_run_base"

# Find the corresponding motion-corrected run directory
export ref_run_dir="$output_dir/$ref_run_base"

# Check for special naming pattern (double acq-)
if [[ $ref_run_base == *"acq-"*"acq-"* ]]; then
    ref4D="${ref_run_dir}/${ref_run_base}_desc-mc_bold.nii.gz"
else
    ref4D="${ref_run_dir}/${ref_run_base}_desc-mc_bold.nii.gz"
fi

if [ ! -f "$ref4D" ]; then
    echo "ERROR: Reference motion-corrected file not found: $ref4D"
    exit 1
fi

echo "Reference volume will be created from: ${ref4D}"

# Get all motion-corrected run directories (for later processing)
all_run_dirs=($(find "$output_dir" -type d -maxdepth 1 -not -path "$output_dir" -not -path "$output_dir/reference" | sort))


# Create reference volume directory
ref_vol_dir="$output_dir/reference"
mkdir -p "$ref_vol_dir"

# Ensure refVol.nii.gz does not exist
if [ -f "${ref_vol_dir}/refVol.nii.gz" ]; then
    echo "Reference volume already exists: ${ref_vol_dir}/refVol.nii.gz. Skipping creation."
else
    echo "Creating reference volume from: ${ref4D}"
    # Create refVol.nii.gz
    3dbucket -prefix ${ref_vol_dir}/refVol.nii.gz ${ref4D}[0]
fi




# ==============================================
# Align refVol.nii.gz with brain.mgz (BBR)
# ==============================================

# Set FreeSurfer subject
export subj=${subj_number}_${session}_iso
echo "Using FreeSurfer subject: $subj"
export brain_mgz="${SUBJECTS_DIR}/${subj}/mri/brain.mgz"

if [ -f "$brain_mgz" ]; then
    # Check if BBR registration has already been done
    if [ -f "${ref_vol_dir}/refVol_to_brain.dat" ]; then
        echo "BBR registration file already exists: ${ref_vol_dir}/refVol_to_brain.dat. Skipping bbregister."
        bbregister_success=true
    else
        echo "Running FreeSurfer's bbregister for BBR alignment..."
        bbregister --s ${subj} \
                   --mov ${ref_vol_dir}/refVol.nii.gz \
                   --reg ${ref_vol_dir}/refVol_to_brain.dat \
                   --init-header \
                   --init-fsl \
                   --t2 \
                   --bold 
        
        if [ $? -ne 0 ]; then
            echo "WARNING: bbregister failed for ${subj}. Skipping coregistration."
            bbregister_success=false
        else
            bbregister_success=true
        fi
        echo "Done running bbregister"
    fi

    if [ "$bbregister_success" = true ]; then
        # Apply the registration to the motion compensated functional image
        if [[ $ref_run_base == *"acq-"*"acq-"* ]]; then
            # Handle special case for RS with double acq-
            ref_coreg_output="${ref_run_dir}/${ref_run_base}_desc-coreg_bold.nii.gz"
        else
            # Handle standard naming pattern
            ref_coreg_output="${ref_run_dir}/${ref_run_base}_desc-coreg_bold.nii.gz"
        fi

        if [ -f "$ref_coreg_output" ]; then
            echo "Reference coregistered file already exists: $ref_coreg_output. Skipping."
        else
            echo "Applying BBR registration to reference run..."
            mri_vol2vol --mov ${ref4D} \
                        --targ ${brain_mgz} \
                        --reg ${ref_vol_dir}/refVol_to_brain.dat \
                        --o ${ref_coreg_output} \
                        --no-resample

            if [ $? -ne 0 ]; then
                echo "WARNING: mri_vol2vol failed for reference run"
            fi
        fi
    fi
else
    echo "ERROR: brain.mgz not found at $brain_mgz"
    echo "Please ensure FreeSurfer processing is complete for subject: $subj"
    exit 1
fi



# ==============================================
# Align remaining runs to refVol.nii.gz
# ==============================================

echo "Starting alignment of remaining runs to reference volume..."

# Get all motion-corrected run directories
all_run_dirs=($(find "$output_dir" -type d -maxdepth 1 -not -path "$output_dir" -not -path "$ref_vol_dir" | sort))

for run_dir in "${all_run_dirs[@]}"; do
    run_base=$(basename "$run_dir")
    
    # Skip the reference run
    if [[ "$run_dir" == "$ref_run_dir" ]]; then
        echo "Skipping reference directory: $run_base"
        continue
    fi
    
    echo "Processing directory: $run_base"
    
    # Define input and output files based on naming pattern
    if [[ $run_base == *"acq-"*"acq-"* ]]; then
        # Handle special case for RS with double acq-
        input_volume="${run_dir}/${run_base}_desc-mc_bold.nii.gz"
        output_affine="${run_dir}/${run_base}_to_refVol_affine.aff12.1D"
        output_aligned="${run_dir}/${run_base}_desc-aligned_bold.nii.gz"
    else
        # Handle standard naming pattern
        input_volume="${run_dir}/${run_base}_desc-mc_bold.nii.gz"
        output_affine="${run_dir}/${run_base}_to_refVol_affine.aff12.1D"
        output_aligned="${run_dir}/${run_base}_desc-aligned_bold.nii.gz"
    fi
    
    # Check if input volume exists
    if [ ! -f "$input_volume" ]; then
        echo "ERROR: Input volume not found: $input_volume"
        continue
    fi
    
    # Check if alignment has already been done
    if [ -f "$output_aligned" ]; then
        echo "Aligned file already exists: $output_aligned. Skipping alignment."
        continue
    fi
    
    echo "Aligning $run_base to reference volume..."
    
    # Step 1: Align the first volume of the run to refVol.nii.gz
    if ! 3dAllineate -base "${ref_vol_dir}/refVol.nii.gz" \
                     -source "${input_volume}[0]" \
                     -1Dmatrix_save "${output_affine}" \
                     -prefix "${run_dir}/${run_base}_aligned_first_vol.nii.gz" \
                     -final wsinc5 \
                     -cost lpa; then
        echo "ERROR: First volume alignment failed for $run_base"
        rm -f "${run_dir}/${run_base}_aligned_first_vol.nii.gz"
        continue
    fi
    
    # Step 2: Apply the affine transformation to the entire 4D volume
    if ! 3dAllineate -base "${ref_vol_dir}/refVol.nii.gz" \
                     -source "${input_volume}" \
                     -1Dmatrix_apply "${output_affine}" \
                     -prefix "${output_aligned}" \
                     -final wsinc5; then
        echo "ERROR: Full volume alignment failed for $run_base"
        rm -f "${output_aligned}"
        continue
    fi
    
    # Clean up intermediate files
    rm -f "${run_dir}/${run_base}_aligned_first_vol.nii.gz"
    echo "Successfully aligned $run_base to reference volume"
    
done

echo "All remaining runs aligned to refVol.nii.gz"


# ==============================================
# Apply refVol_to_brain.dat to aligned runs
# ==============================================

if [ "$bbregister_success" = true ] && [ -f "${ref_vol_dir}/refVol_to_brain.dat" ]; then
    echo "Starting coregistration of aligned runs to anatomical space..."

    for run_dir in "${all_run_dirs[@]}"; do
        run_base=$(basename "$run_dir")
        
        # Skip the reference run as it was already processed
        if [[ "$run_dir" == "$ref_run_dir" ]]; then
            echo "Skipping reference directory: $run_base (already processed)"
            continue
        fi
        
        # Define input and output files based on naming pattern
        if [[ $run_base == *"acq-"*"acq-"* ]]; then
            # Handle special case for RS with double acq-
            input_volume="${run_dir}/${run_base}_desc-aligned_bold.nii.gz"
            output_volume="${run_dir}/${run_base}_desc-coreg_bold.nii.gz"
        else
            # Handle standard naming pattern
            input_volume="${run_dir}/${run_base}_desc-aligned_bold.nii.gz"
            output_volume="${run_dir}/${run_base}_desc-coreg_bold.nii.gz"
        fi
        
        # Check if input volume exists
        if [ ! -f "$input_volume" ]; then
            echo "ERROR: Input volume not found: $input_volume"
            continue
        fi
        
        # Check if coregistration has already been done
        if [ -f "$output_volume" ]; then
            echo "Coregistered file already exists: $output_volume. Skipping."
            continue
        fi
        
        echo "Applying refVol_to_brain.dat registration to $run_base..."
        
        # Apply the registration using mri_vol2vol
        if ! mri_vol2vol --mov ${input_volume} \
                        --targ ${brain_mgz} \
                        --reg ${ref_vol_dir}/refVol_to_brain.dat \
                        --o ${output_volume} \
                        --no-resample; then
            echo "ERROR: Coregistration failed for $run_base"
            rm -f "${output_volume}"
            continue
        fi
        
        # Verify output file exists and has expected size
        if [ ! -f "$output_volume" ]; then
            echo "ERROR: Output file not created: $output_volume"
            continue
        fi
        
        echo "Successfully coregistered $run_base to anatomical space"
        echo "Output saved to: ${output_volume}"
    done

    echo "All aligned runs coregistered to anatomical space"
else
    echo "WARNING: Cannot proceed with anatomical coregistration (bbregister failed or file missing)"
fi
