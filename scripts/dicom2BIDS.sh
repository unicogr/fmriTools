#!/bin/bash

# Load configuration values from conf.yaml (using yq)
user_folder=$(yq -r '.Paths.user_folder' conf.yaml)
project_folder=$(yq -r '.Paths.project_folder' conf.yaml)

anat_type=$(yq -r '.MRI.anatomical' conf.yaml)
echo "Anatomy data type: $anat_type"

func_type=$(yq -r '.MRI.functional' conf.yaml)
echo "Functional data type: $func_type"

output_folder="${user_folder%/}/${project_folder#/}/output"

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
programs_path=$(yq -r '.Paths.programs_path' conf.yaml)
data_path=$(yq -r '.Paths.data_path' conf.yaml)

# Extract subject ID and date for the given subject number
subj_id=$(yq -r ".Subjects[\"${subj_number}\"].id" conf.yaml)
date=$(yq -r ".Subjects[\"${subj_number}\"].date" conf.yaml)

echo "Subject ID: $subj_id"
echo "Subject Date: $date"

input_folder=${data_path}/${date}/${subj_id}
echo "input folder: $input_folder" # Add echo to test



# # Freesurfer
# unset FREESURFER_HOME
# #export FREESURFER_HOME=${programs_path}freesurfer/8.0.0
# export FREESURFER_HOME=${programs_path}/freesurfer
# source $FREESURFER_HOME/SetUpFreeSurfer.sh
# #export SUBJECTS_DIR=$FREESURFER_HOME/subjects
# export SUBJECTS_DIR=${user_folder}/fs_subjects
# mkdir -p $SUBJECTS_DIR

# # FSL
# FSLDIR=${programs_path}/fsl
# . ${FSLDIR}/etc/fslconf/fsl.sh
# PATH=${FSLDIR}/bin:${PATH}
# export FSLDIR PATH

# # ANTs
# export PATH=${programs_path}/ants-2.5.4/bin:$PATH

# Print conf variables
echo "Programs path: $programs_path"
echo "Project name: $project_folder"  # Fixed typo from "pame"
echo "Data path: $data_path"


# ==============================================
# Load pre-computed indexing from image_index.txt
# ==============================================


image_index_file="${output_folder}/${subj_number}/${session}/image_index.txt"

if [ ! -f "$image_index_file" ]; then
  echo "ERROR: image_index.txt not found at $image_index_file. Run the indexing script first or create/edit the file manually."
  #exit 1
fi

echo "Loading indexing from: $image_index_file"

# Initialize arrays
unset moving_images
unset static_images
declare -A moving_images
declare -A static_images
declare -A SBRef_images

# Parse Moving images section
moving_section=$(awk '/Moving images \(sorted by index\):/{flag=1; next} /Static images \(sorted by index\):/{flag=0} flag && /^[[:space:]]*[0-9]+:/ {print $0}' "$image_index_file" | sed 's/^[[:space:]]*\([0-9]\):[[:space:]]*\(.*\)/\1 \2/')
while read -r idx folder; do
  moving_images["$idx"]="$folder"
  echo "Loaded moving image $idx: $folder"
done <<< "$moving_section"

# Parse Static images section
static_section=$(awk '/Static images \(sorted by index\):/{flag=1; next} flag && /^[[:space:]]*[0-9]+:/ {print $0}' "$image_index_file" | sed 's/^[[:space:]]*\([0-9]\):[[:space:]]*\(.*\)/\1 \2/')
while read -r idx folder; do
  static_images["$idx"]="$folder"
  echo "Loaded static image $idx: $folder"
done <<< "$static_section"

# Parse SBRef images section
SBRef_section=$(awk '/SBRef images \(sorted by index\):/{flag=1; next} flag && /^[[:space:]]*[0-9]+:/ {print $0}' "$image_index_file" | sed 's/^[[:space:]]*\([0-9]\):[[:space:]]*\(.*\)/\1 \2/')
while read -r idx folder; do
  SBRef_images["$idx"]="$folder"
  echo "Loaded SBRef image $idx: $folder"
done <<< "$SBRef_section"

# Parse Anatomical images section
anat_section=$(awk '/Anatomical images \(sorted by index\):/{flag=1; next} flag && /^[[:space:]]*[0-9]+:/ {print $0}' "$image_index_file" | sed 's/^[[:space:]]*\([0-9]\):[[:space:]]*\(.*\)/\1 \2/')
declare -A anat_images
while read -r idx folder; do
  anat_images["$idx"]="$folder"
  echo "Loaded anatomical image $idx: $folder"
done <<< "$anat_section"


# Set counter to the number of loaded images (for compatibility with later loops)
counter=$((${#moving_images[@]} > ${#static_images[@]} ? ${#moving_images[@]} : ${#static_images[@]}))
counter=$((counter + 1))

# Still load task_patterns from YAML for conversion (not stored in image_index.txt)
task_patterns=()
mapfile -t task_patterns < <(yq -r '.Tasks | to_entries[] | .value' conf.yaml)

# Optional: Echo loaded data for verification
echo "Loaded ${#moving_images[@]} moving images, ${#static_images[@]} static images, ${#SBRef_images[@]} SBRef images, and ${#anat_images[@]} anatomical images."
echo "Task patterns: ${task_patterns[*]}"

# Function to extract pattern from folder name
extract_pattern() {
    local folder="$1"
    for pattern in "${task_patterns[@]}"; do
        if [[ "$folder" == *"$pattern"* ]]; then
            echo "$pattern"
            return
        fi
    done
    echo ""
}


# ==============================================
# Convert anatomical DICOM to NIfTI (BIDS format)
# ==============================================

# anat_type already loaded from conf.yaml at the top
echo "Anatomy data type: $anat_type"

anat_nifti="${output_folder}/${subj_number}/${session}/anat"
mkdir -p "$anat_nifti"


if [[ "$anat_type" == "mprage-sag" ]]; then

    # --- MPRAGE handling ---

    anat_dicom_folder=$(find "$input_folder" -type d -name "*${anat_type}*" | head -n 1)
    echo "Anatomy dicom folder: $anat_dicom_folder"
    anat_nii_out="${anat_nifti}/${subj_number}_${session}_T1w.nii.gz"
    anat_json_out="${anat_nifti}/${subj_number}_${session}_T1w.json"

    if [ -d "$anat_dicom_folder" ]; then
      if [ ! -f "$anat_nii_out" ]; then
        echo "Converting anatomical DICOMs in: $anat_dicom_folder"
        dcm2niix_afni -z y -o "$anat_nifti" "$anat_dicom_folder"

        # Find the generated NIfTI and JSON files
        nifti_file=$(find "$anat_nifti" -maxdepth 1 -type f -name "*.nii.gz" | head -n 1)
        json_file=$(find "$anat_nifti" -maxdepth 1 -type f -name "*.json" | head -n 1)

        # Rename to BIDS format
        if [ -f "$nifti_file" ]; then
          mv "$nifti_file" "$anat_nii_out"
          echo "Renamed NIfTI to $anat_nii_out"
        fi
        if [ -f "$json_file" ]; then
          mv "$json_file" "$anat_json_out"
          echo "Renamed JSON to $anat_json_out"
        fi
      else
        echo "Skipping anatomical conversion (already exists: $anat_nii_out)"
      fi
    else
      echo "No anatomical DICOM folder found for pattern: $anat_type"
    fi

elif [[ "$anat_type" == "mp2rage-sag" ]]; then

    # --- MP2RAGE handling from image_index.txt ---

    found_any=0

    for idx in $(printf '%s\n' "${!anat_images[@]}" | sort -n); do
        folder="${anat_images[$idx]}"
        if [ -z "$folder" ]; then continue; fi
        found_any=1

        # Determine suffix from folder name
        if [[ "$folder" == *INV1* && "$folder" == *PHS* ]]; then suffix="inv-1_part-phase_MP2RAGE"
        elif [[ "$folder" == *INV1* ]]; then suffix="inv-1_part-mag_MP2RAGE"
        elif [[ "$folder" == *INV2* && "$folder" == *PHS* ]]; then suffix="inv-2_part-phase_MP2RAGE"
        elif [[ "$folder" == *INV2* ]]; then suffix="inv-2_part-mag_MP2RAGE"
        elif [[ "$folder" == *T1-Images* ]]; then suffix="T1map"
        elif [[ "$folder" == *UNI-DEN* ]]; then suffix="UNIT1"
        elif [[ "$folder" == *UNI-Images* ]]; then suffix="UNIDEN"
        else suffix="$folder"; fi

        nii_out="${anat_nifti}/${subj_number}_${session}_${suffix}.nii.gz"
        json_out="${anat_nifti}/${subj_number}_${session}_${suffix}.json"

        if [ ! -f "$nii_out" ]; then
          echo "Converting anatomical DICOMs in: $folder"
          dcm2niix_afni -z y -o "$anat_nifti" "${input_folder}/${folder}"

          # Find the generated NIfTI and JSON files (most recent)
          nifti_file=$(find "$anat_nifti" -maxdepth 1 -type f -name "*.nii.gz" -printf "%T@ %p\n" | sort -n | tail -n 1 | cut -d' ' -f2-)
          json_file=$(find "$anat_nifti" -maxdepth 1 -type f -name "*.json" -printf "%T@ %p\n" | sort -n | tail -n 1 | cut -d' ' -f2-)

          # Rename to BIDS format
          if [ -f "$nifti_file" ]; then
            mv "$nifti_file" "$nii_out"
            echo "Renamed NIfTI to $nii_out"
          fi
          if [ -f "$json_file" ]; then
            mv "$json_file" "$json_out"
            echo "Renamed JSON to $json_out"
          fi
        else
          echo "Skipping $folder conversion (already exists: $nii_out)"
        fi
    done

    if [ $found_any -eq 0 ]; then echo "No anatomical DICOM folders listed in image_index.txt."; fi

else
    echo "Unknown anatomical pattern: $anat_type"
fi



# ==============================================
# Create BIDS directory structure
# ==============================================
mkdir -p "${output_folder}/${subj_number}/${session}/anat"
mkdir -p "${output_folder}/${subj_number}/${session}/fmap"
mkdir -p "${output_folder}/${subj_number}/${session}/func"

# Show the created folder structure (directories only)
#tree -d "${output_folder}"


fmap_out_dir="${output_folder}/${subj_number}/${session}/fmap"
mkdir -p "${fmap_out_dir}"

echo "fmap output directory: $fmap_out_dir"
echo "Input folder: $input_folder"

# ==============================================
# Print various information to textfile
# ==============================================

# Get all task patterns from config file (indexable array)
mapfile -t task_patterns < <(yq -r '.Tasks | to_entries[] | .value' conf.yaml)

# Parse static images from file and print with task patterns
echo "Static images and task patterns (sorted by index):"
j=0
while read -r idx folder; do
    pattern="${task_patterns[$j]}"
    # Extract base name (strip trailing digits) and run number (last digits)
    if [[ "$pattern" =~ ^([A-Za-z]+)[^0-9]*([0-9]+)?$ ]]; then
        base_name="${BASH_REMATCH[1]}"
        run_num="${BASH_REMATCH[2]}"
        if [[ -n "$run_num" ]]; then
            run_num=$(printf "%02d" "$run_num")
        else
            run_num=""
        fi
    else
        base_name="$pattern"
        run_num=""
    fi
    printf "  %d: %s | task: '%s' | run: '%s'\n" "$((j+1))" "$folder" "$base_name" "$run_num"
    ((j++))
done <<< "$static_section"



# ==============================================
# Convert functional DICOMs to NIfTI
# ==============================================

# func_type already loaded from conf.yaml at the top
echo "Functional data type: $func_type"


func_out_dir="${output_folder}/${subj_number}/${session}/func"
mkdir -p "$func_out_dir"

for idx in $(printf '%s\n' "${!static_images[@]}" | sort -n); do
    static_folder="${static_images[$idx]}"
    moving_folder="${moving_images[$idx]}"
    SBRef_folder="${SBRef_images[$idx]}"

    [ -z "$static_folder" ] && continue

    # Extract pattern from moving_folder name
    pattern=$(extract_pattern "$moving_folder")
    if [ -z "$pattern" ]; then
        echo "Warning: Could not extract pattern from $moving_folder, skipping"
        continue
    fi
    # Extract base name (strip trailing digits) and run number (last digits)
    if [[ "$pattern" =~ ^([A-Za-z]+)[^0-9]*([0-9]+)?$ ]]; then
        base_name="${BASH_REMATCH[1]}"
        run_num="${BASH_REMATCH[2]}"
        if [[ -n "$run_num" ]]; then
            run_num=$(printf "%02d" "$run_num")
            run_part="_run-${run_num}"
        else
            run_part=""
        fi
    else
        base_name="$pattern"
        run_part=""
    fi

    echo "  $idx: task: '$base_name' | run: '$run_num'"
    

    # File names for output
    # Determine direction based on image type from image_index.txt patterns
    # Moving and SBRef images have -AP-, so dir-ap
    # Static images have -PA-, so dir-pa
    out_prefix_opposite=${subj_number}"_${session}_acq-${base_name}_dir-pa${run_part}_${func_type}"

    out_prefix_func=${subj_number}"_${session}_acq-${base_name}_dir-ap${run_part}_${func_type}_bold"

    out_prefix_SBRef=${subj_number}"_${session}_acq-${base_name}_dir-ap${run_part}_SBRef"


    # Convert DICOMs to NIfTI using dcm2niix_afni
    if [ -n "$SBRef_folder" ]; then
        sbref_nii="${func_out_dir}/${out_prefix_SBRef}.nii.gz"
        if [ ! -f "$sbref_nii" ]; then
            echo "Converting SBRef image to NiFTI: $SBRef_folder"
            dcm2niix_afni -z y -f "$out_prefix_SBRef" -o "${func_out_dir}" "${input_folder}/${SBRef_folder}"
        else
            echo "Skipping $SBRef_folder (already converted: $sbref_nii exists)"
        fi
    fi

    if [ -n "$static_folder" ]; then
        opposite_nii="${func_out_dir}/${out_prefix_opposite}.nii.gz"
        if [ ! -f "$opposite_nii" ]; then
            echo "Converting functional image with opposite encoding to NiFTI: $static_folder"
            dcm2niix_afni -z y -f "$out_prefix_opposite" -o "${func_out_dir}" "${input_folder}/${static_folder}"
        else
            echo "Skipping $static_folder (already converted: $opposite_nii exists)"
        fi
    fi

    if [ -n "$moving_folder" ]; then
        func_nii="${func_out_dir}/${out_prefix_func}.nii.gz"
        echo "Input folder: $input_folder"
        echo "Moving folder: $moving_folder"
        if [ ! -f "$func_nii" ]; then
            echo "Converting functional image to NiFTI: $moving_folder"
            dcm2niix_afni -z y -f "$out_prefix_func" -o "${func_out_dir}" "${input_folder}/${moving_folder}"
        else
            echo "Skipping $moving_folder (already converted: $func_nii exists)"
        fi
    fi


done

echo "Converted files are saved in: $fmap_out_dir and $func_out_dir"
