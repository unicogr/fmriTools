#!/bin/bash
#
# This script projects motion-corrected and anatomically registered BOLD data
# to FreeSurfer surface space.
#
# Input:
# - Motion-corrected and coregistered BOLD runs (*_desc-coreg_bold.nii.gz)
# - FreeSurfer-processed anatomical data (brain.mgz)
#
# Output:
# - Surface-projected files (lh/rh.<run>_desc-surf.mgh)
#
# Usage: 
#     bash projSurf_3T.sh <subject_id> <session_id>
# Example:
#     bash projSurf_3T.sh sub-01 ses-01
#
# Dependencies:
# - FreeSurfer
#

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
user_folder=$(yq -r '.Paths.user_folder' conf.yaml)
project_folder=$(yq -r '.Paths.project_folder' conf.yaml)
programs_path=$(yq -r '.Paths.programs_path' conf.yaml)

# Get all task patterns from conf.yaml
task_patterns=()
mapfile -t task_patterns < <(yq -r '.Tasks | to_entries[] | .value' conf.yaml)

# Setup FreeSurfer
export FREESURFER_HOME=${programs_path}/freesurfer
source $FREESURFER_HOME/SetUpFreeSurfer.sh

# Set FreeSurfer subjects directory
export SUBJECTS_DIR="${user_folder}/${project_folder}/output/fs_subjects"

echo "=========================================================="
echo "Processing: ${subj_number} / ${session}"
echo "=========================================================="

# Define input and output directories
input_dir="${user_folder}/${project_folder}/output/derivatives/motion-compensated/${subj_number}/${session}/func"
output_dir="${user_folder}/${project_folder}/output/derivatives/surf-projected/${subj_number}/${session}/func"
mkdir -p "$output_dir"

# Define the FreeSurfer subject ID
export subj="${subj_number}_${session}_iso"

# Find all coregistered BOLD files
mapfile -t coreg_files < <(find "$input_dir" -type f -name "*_desc-coreg_bold.nii.gz" | sort)

if [ ${#coreg_files[@]} -eq 0 ]; then
    echo "ERROR: No coregistered files found for ${subj_number}"
    exit 1
fi

# Loop through each coregistered file
for moving_image in "${coreg_files[@]}"; do
    run_base=$(basename "$moving_image" _desc-coreg_bold.nii.gz)
    echo "Processing run: ${run_base}"

    # Handle both standard and special (double acq-) naming patterns
    if [[ $run_base == *"acq-"*"acq-"* ]]; then
        # Special case for RS with double acq-
        output_prefix="${run_base}"
    else
        # Standard naming pattern
        output_prefix="${run_base}"
    fi

    for hemi in lh rh; do
        output_surface="${output_dir}/${hemi}.${output_prefix}_desc-surf.mgh"

        # Check if output exists
        if [ -f "$output_surface" ]; then
            echo "Surface file exists, skipping: ${output_surface}"
            continue
        fi

        echo "Projecting to ${hemi} surface..."
        
        # Project volume to surface using FreeSurfer
        if ! mri_vol2surf --mov ${moving_image} \
                         --regheader ${subj} \
                         --hemi ${hemi} \
                         --projfrac 0.5 \
                         --interp trilinear \
                         --surf white \
                         --out ${output_surface}; then
            echo "ERROR: Surface projection failed for ${hemi}.${output_prefix}"
            rm -f "${output_surface}"
            continue
        fi

        echo "Successfully projected to ${hemi} surface"
    done
done

echo "Finished all projections for ${subj_number}"
