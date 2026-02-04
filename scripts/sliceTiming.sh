#!/bin/bash
# BIDS-compatible slice timing correction for 7T data
# Usage: bash sliceTiming_3T.sh sub-01 ses-01

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
func_type=$(yq -r '.MRI.functional' conf.yaml)



# Setup tool paths
export FREESURFER_HOME=${programs_path}/freesurfer
source $FREESURFER_HOME/SetUpFreeSurfer.sh

FSLDIR=${programs_path}/fsl
. ${FSLDIR}/etc/fslconf/fsl.sh
PATH=${FSLDIR}/bin:${PATH}
export FSLDIR PATH

export PATH=${programs_path}/ants-2.5.4/bin:$PATH

# BIDS directory structure
bids_dir="${user_folder}/${project_folder}/output"
func_folder="${bids_dir}/${subj_number}/${session}/func"
output_dir="${bids_dir}/derivatives/slice-timing-corrected/${subj_number}/${session}/func"

# Create output directory
mkdir -p "$output_dir"

echo "Processing BIDS functional data for ${subj_number}/${session}"
echo "Input directory: $func_folder"
echo "Output directory: $output_dir"
echo "Functional data type: $func_type"

# Get all task patterns from conf.yaml
task_patterns=()
mapfile -t task_patterns < <(yq -r '.Tasks | to_entries[] | .value' conf.yaml)

echo "Task patterns: ${task_patterns[*]}"

# Loop over each task pattern
for pattern in "${task_patterns[@]}"; do
    # Extract base_name from pattern, same as in dicom2BIDS
    if [[ "$pattern" =~ ^([A-Za-z]+)[^0-9]*([0-9]+)?$ ]]; then
        base_name="${BASH_REMATCH[1]}"
    else
        base_name="$pattern"
    fi
    
    echo "Processing task pattern: $pattern (base_name: $base_name)"
    
    # Find all bold files matching the base_name
    mapfile -t bold_files < <(find "$func_folder" -name "*acq-${base_name}*bold.nii.gz" -type f)
    
    if [ ${#bold_files[@]} -eq 0 ]; then
        echo "No bold files found for base_name: $base_name"
        continue
    fi
    
    for input_file in "${bold_files[@]}"; do
        echo "Processing file: $input_file"
        
        # Extract run from filename if present (e.g., _run-01_)
        run_part=""
        if [[ "$input_file" =~ _run-([0-9]+)_ ]]; then
            run_num="${BASH_REMATCH[1]}"
            run_part="_run-${run_num}"
        fi
        
        # Output filename
        base_name=$(basename "$input_file" .nii.gz)
        output_file="${output_dir}/${base_name}_desc-stc_bold.nii.gz"
        output_json="${output_dir}/${base_name}_desc-stc_bold.json"
        slice_timing_file="${output_dir}/${base_name}_SliceTiming.txt"
        
        sidecar_json="${input_file/.nii.gz/.json}"
        
        if [ ! -f "$sidecar_json" ]; then
            echo "JSON file not found: $sidecar_json, skipping."
            continue
        fi
        
        if [ -f "$output_file" ]; then
            echo "Output already exists: $output_file, skipping."
            continue
        fi
        
        TR=$(jq -r '.RepetitionTime' "$sidecar_json")
        slice_timing_available=$(jq 'has("SliceTiming")' "$sidecar_json")
        if [ "$slice_timing_available" = "false" ]; then
            echo "SliceTiming not found in $sidecar_json, skipping."
            continue
        fi
        
        jq -r '.SliceTiming[]' "$sidecar_json" > "$slice_timing_file"
        echo "SliceTiming saved to: $slice_timing_file"
        
        echo "Running 3dTshift for $input_file ..."
        3dTshift -verbose -TR "$TR" \
                -tpattern @"$slice_timing_file" \
                -wsinc9 \
                -prefix "$output_file" \
                "$input_file"
        
        jq --arg desc "Slice timing corrected using AFNI 3dTshift with custom slice timing pattern" \
           --arg source_file "$(basename "$input_file")" \
           '. + {"Description": $desc, "Sources": [$source_file], "SliceTimingCorrected": true}' "$sidecar_json" > "$output_json"
        rm -f "$slice_timing_file"
        echo "Done: $output_file"
    done
done
