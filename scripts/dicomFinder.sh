#!/bin/bash

# Load configuration values efficiently using yq
{
read -r user_folder
read -r project_folder
read -r anat_type
read -r func_type
} < <(yq -r '.Paths.user_folder, .Paths.project_folder, .MRI.anatomical, .MRI.functional' conf.yaml)

echo "User folder: $user_folder"
echo "Project folder: $project_folder"
echo "Anatomy data type: $anat_type"
echo "Functional data type: $func_type"



output_folder=${user_folder}${project_folder}/output



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




# Print conf variables
echo "Programs path: $programs_path"
echo "Project pame: $project_name"
echo "Data path: $data_path"


# ==============================================
# Organize the functional data
# ==============================================

# Create a folder for the functional nifti files
func_nifti="${output_folder}/${subj_number}/${session}"
mkdir -p "$func_nifti"
echo "Functional Nifti folder: $func_nifti"

# IMPORTANT: Reset arrays for each pattern

unset moving_images
unset static_images

declare -A moving_images
declare -A static_images

echo "Processing subject: $subj_id"


# ==============================================
# Get all task patterns from config file
# ==============================================
task_patterns=()
yq -c '.Tasks | to_entries[]' conf.yaml | while read -r entry; do
  task=$(echo "$entry" | yq -r '.key')
  pattern=$(echo "$entry" | yq -r '.value')
  task_patterns+=("$pattern")
  echo "Found task pattern: $pattern"
done

# Kind of redundant
task_patterns=()
mapfile -t task_patterns < <(yq -r '.Tasks | to_entries[] | .value' conf.yaml)

declare -A moving_images
counter=1

# Identify folders holding each task pattern and index them, taking care of digit formatting
echo -e "\nIdentifying folders holding each task pattern:"
for pattern in "${task_patterns[@]}"; do
  echo -e "\nSearching for folders matching pattern: $pattern"

  mapfile -t matching_folders < <(find "$input_folder" -type d -name "*${pattern}*" ! -name "*SBRef*")

  if [ ${#matching_folders[@]} -eq 0 ]; then
    echo "  No folders found for pattern: $pattern"
  else

    # Filter out folders containing "split"
    filtered_folders=()
    for folder in "${matching_folders[@]}"; do
      folder_name=$(basename "$folder")
      if [[ "$folder_name" != *split* ]]; then
        filtered_folders+=("$folder")
      fi
    done
    matching_folders=("${filtered_folders[@]}")

    # Find the folder with the smallest leading index
    min_index=999999
    min_folder=""
    for folder in "${matching_folders[@]}"; do
      folder_name=$(basename "${folder}")
      index=$(echo "$folder_name" | awk -F'_' '{print $1}' | sed 's/^0*//') # Remove leading zeros
      if [[ "$index" =~ ^[0-9]+$ ]] && (( index < min_index )); then
        min_index=$index
        min_folder=$folder_name
      fi
    done
    if [ -n "$min_folder" ]; then
      moving_images["${counter}"]="${min_folder}"
      echo "    Keeping: $min_folder (index $min_index)"
      counter=$((counter + 1))
    fi
  fi
done


  
# ==============================================
# Ensure static images are indexed correctly
# ==============================================
counter=1
for pattern in "${task_patterns[@]}"; do
  echo -e "\nProcessing pattern: $pattern for subject: $(basename "$subj_id")"

  # Find functional folders matching the pattern in the subject's directory
  mapfile -t func_folders < <(find "$input_folder" -type d -name "*${pattern}*" ! -name "*SBRef*" ! -name "*split*")


  # Skip if no folders found
  if [ ${#func_folders[@]} -eq 0 ]; then
    echo "No functional folders found matching '$pattern' for this subject"
    continue
  fi

  # Find the folder with the smallest leading index
  min_index=999999
  min_folder_name=""
  for folder in "${func_folders[@]}"; do
    folder_name=$(basename "$folder")
    index=$(echo "$folder_name" | awk -F'_' '{print $1}' | sed 's/^0*//')
    if [[ "$index" =~ ^[0-9]+$ ]] && (( index < min_index )); then
      min_index=$index
      min_folder_name=$folder_name
    fi
  done

  if [ -n "$min_folder_name" ]; then
    folder="${input_folder}/${min_folder_name}"
    moving_images["${counter}"]="${min_folder_name}"

    # Extract index from folder name (assume index is before first '_')
    folder_index=$(echo "${min_folder_name}" | awk -F'_' '{print $1}')

    # Calculate static image index (2 less than moving)
    if [[ "$folder_index" =~ ^[0-9]+$ ]]; then
      num_digits=${#folder_index}
      folder_index_dec=$((10#${folder_index}))
      static_index_dec=$((folder_index_dec - 2))
      if (( static_index_dec > 0 )); then
        static_index=$(printf "%0${num_digits}d" "${static_index_dec}")
      else
        static_index=""
      fi
    else
      numeric_part=$(echo "$folder_index" | grep -o '[0-9]\+')
      if [ -n "$numeric_part" ]; then
        num_digits=${#numeric_part}
        folder_index_dec=$((10#${numeric_part}))
        static_index_dec=$((folder_index_dec - 2))
        if (( static_index_dec > 0 )); then
          static_index=$(printf "%0${num_digits}d" "${static_index_dec}")
          static_index="${folder_index/$numeric_part/$static_index}"
        else
          static_index=""
        fi
      else
        static_index=""
      fi
    fi

    echo "  Moving: $min_folder_name"
    echo "  Static image index: $static_index"

    # Find corresponding static folder if we have an index
    static_folder=""
    if [ -n "$static_index" ]; then
      static_folder=$(find "$input_folder" -type d -name "${static_index}_*" ! -name "*SBRef*" | head -n 1)
    fi
    if [ -n "$static_folder" ]; then
      static_images["${counter}"]="$(basename "$static_folder")"
      echo "  Static: $(basename "$static_folder")"
    else
      echo "  No static image found at index $static_index, searching lower indices..."
      # Search for the nearest index below
      if [[ "$folder_index" =~ ^[0-9]+$ ]]; then
        for ((i = folder_index_dec - 1; i >= 1; i--)); do
          nearest_static_index=$(printf "%0${num_digits}d" "$i")
          nearest_static_folder=$(find "$input_folder" -type d -name "${nearest_static_index}_*" ! -name "*SBRef*" | head -n 1)
          if [ -n "$nearest_static_folder" ]; then
            static_images["${counter}"]="$(basename "$nearest_static_folder")"
            echo "  Found nearest static: $(basename "$nearest_static_folder")"
            break
          fi
        done
      elif [ -n "$numeric_part" ]; then
        for ((i = folder_index_dec - 1; i >= 1; i--)); do
          nearest_static_index=$(printf "%0${num_digits}d" "$i")
          candidate_index="${folder_index/$numeric_part/$nearest_static_index}"
          nearest_static_folder=$(find "$input_folder" -type d -name "${candidate_index}_*" ! -name "*SBRef*" | head -n 1)
          if [ -n "$nearest_static_folder" ]; then
            static_images["${counter}"]="$(basename "$nearest_static_folder")"
            echo "  Found nearest static: $(basename "$nearest_static_folder")"
            break
          fi
        done
      else
        static_images["${counter}"]=""
        echo "  No static image found and no previous static image available."
      fi
    fi

    counter=$((counter + 1))
    echo "----------------------------------------"
  fi
done


echo "Moving images (sorted by index):"
for idx in $(for i in "${!moving_images[@]}"; do
    folder="${moving_images[$i]}"
    index=$(echo "$folder" | awk -F'_' '{print $1}')
    echo "$index $i"
done | sort | awk '{print $2}'); do
    echo "  $idx: ${moving_images[$idx]}"
done



echo "Static images (sorted by index):"
for idx in $(for i in "${!static_images[@]}"; do
    folder="${static_images[$i]}"
    index=$(echo "$folder" | awk -F'_' '{print $1}')
    echo "$index $i"
done | sort | awk '{print $2}'); do
    echo "  $idx: ${static_images[$idx]}"
done



declare -A SBRef_images

echo "Preceding folders for moving images:"
for idx in $(for i in "${!moving_images[@]}"; do
    folder="${moving_images[$i]}"
    index=$(echo "$folder" | awk -F'_' '{print $1}')
    echo "$index $i"
done | sort | awk '{print $2}'); do
    folder="${moving_images[$idx]}"
    index=$(echo "$folder" | awk -F'_' '{print $1}')
    num_digits=${#index}
    index_dec=$((10#$index))
    prev_index_dec=$((index_dec - 1))
    if (( prev_index_dec > 0 )); then
        prev_index=$(printf "%0${num_digits}d" "$prev_index_dec")
        prev_folder=$(find "$input_folder" -maxdepth 1 -type d -name "${prev_index}_*" | head -n 1)
        SBRef_images["$idx"]="$(basename "$prev_folder")"
        echo "   Moving: $folder"
        if [ -n "$prev_folder" ]; then
            echo "Preceding: $(basename "$prev_folder")"
        else
            echo "Preceding: Not found"
        fi
    else
        SBRef_images["$idx"]=""
        echo "   Moving: $folder"
        echo "Preceding: Not found (no lower index)"
    fi
done





# ==============================================
# Save subject info and moving/static images (sorted by index) to a text file
# ==============================================
{
echo "Subject ID: $subj_id"
echo "Subject Date: $date"
echo "Input folder: $input_folder"
echo "Output file: ${output_folder}/${subj_number}/${session}/image_index.txt"
echo

echo "Moving images (sorted by index):"
for idx in $(for i in "${!moving_images[@]}"; do
    folder="${moving_images[$i]}"
    index=$(echo "$folder" | awk -F'_' '{print $1}')
    echo "$index $i"
done | sort | awk '{print $2}'); do
    echo "  $idx: ${moving_images[$idx]}"
done

echo

echo "Static images (sorted by index):"
for idx in $(for i in "${!static_images[@]}"; do
    folder="${static_images[$i]}"
    index=$(echo "$folder" | awk -F'_' '{print $1}')
    echo "$index $i"
done | sort | awk '{print $2}'); do
    echo "  $idx: ${static_images[$idx]}"
done

echo

echo "SBRef images (sorted by index):"
for idx in $(for i in "${!SBRef_images[@]}"; do
    folder="${SBRef_images[$i]}"
    index=$(echo "$folder" | awk -F'_' '{print $1}')
    echo "$index $i"
done | sort | awk '{print $2}'); do
    echo "  $idx: ${SBRef_images[$idx]}"
done

echo

echo "Anatomical images:"
declare -A anat_images

if [[ "$anat_type" == "mp2rage-sag" ]]; then
    mp2rage_types=("INV1" "INV1-PHS" "INV2" "INV2-PHS" "T1-Images" "UNI-DEN" "UNI-Images")
    counter=1
    for type in "${mp2rage_types[@]}"; do
        folder=$(find "$input_folder" -type d -name "*mp2rage*${type}" | head -n 1)
        if [ -n "$folder" ]; then
            anat_images["$counter"]="$(basename "$folder")"
            echo "  $counter: $(basename "$folder") ($type)"
            counter=$((counter + 1))
        fi
    done
fi

echo

echo "Anatomical images (sorted by index):"
for idx in $(printf '%s\n' "${!anat_images[@]}" | sort -n); do
    echo "  $idx: ${anat_images[$idx]}"
done
} > "${output_folder}/${subj_number}/${session}/image_index.txt"

echo "Saved subject info and image indices to ${output_folder}/${subj_number}/${session}/image_index.txt"