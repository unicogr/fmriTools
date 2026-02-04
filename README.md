# BIDS preprocessing pipeline

*A Python-free alternative to fMRIprep that actually works*

This repository contains a BIDS-compliant preprocessing pipeline for fMRI data at both 3T and 7T field strengths. The pipeline automates the conversion, slice timing correction, distortion correction, motion correction, anatomical registration, and surface projection of DICOM data to BIDS-formatted NIfTI files, with anatomical and functional sequences configured via `conf.yaml`.


> **TODO:**
> 1. Add option to use `ants` for distortion correction and motion compensation
> 2. Add final step to register the native space data to MNI space
> 3. Ensure full BIDS compliance, on the same footing as `neurospin_to_bids`
> 4. Include `fMRIprep`-style diagnostic plots.  

**For questions you can contact**: 
   
Nicolas Gravel <nicolas.gravel@cea.fr>   
Julie Bonnaire <julie.bonnaire@cea.fr>   
Samuel Debray <samuel.debray@ens-paris-saclay.fr>  
Christophe Pallier <christophe@pallier.org>  


## Installation

### Central pipeline repository

The preprocessing scripts and Makefile are maintained in a central location (`/home_local/Nico/fmriTools/`) and shared across multiple projects. This design allows you to:
- Edit scripts once and use them in all projects
- Maintain consistent preprocessing across studies
- Easily update the pipeline without copying files
- Run make from any project directory without local Makefile
- Override scripts locally for project-specific modifications

### One-time environment setup

**Step 1:** Open a terminal

**Step 2:** Add the pipeline to your `~/.bashrc`:

```bash
echo 'export FMRI_PIPELINE_HOME=/home_local/Nico/fmriTools' >> ~/.bashrc
echo 'export PATH=$FMRI_PIPELINE_HOME/scripts:$PATH' >> ~/.bashrc
source ~/.bashrc
```

This adds the scripts to your PATH so they can be called directly from anywhere.

### Running the pipeline in a project

**Step 3:** Navigate to your project folder and set up the Makefile environment:

```bash
cd /path/to/your/project
export FMRI_TOOLS_HOME=/home_local/Nico/fmriTools
export MAKEFILES=$FMRI_TOOLS_HOME/Makefile
```

**Step 4:** Run the pipeline (no local Makefile needed):

```bash
make subj=sub-01 sess=ses-01 image_index
make subj=sub-01 sess=ses-01 bids

# Or in a loop:
for i in {7..12}; do
    subj=$(printf "sub-%02d" $i)
    echo "Processing $subj..."
    make subj=$subj sess=ses-01 bids || { echo "Failed for $subj"; break; }
done

# or run the full pipeline:
make subj=sub-01 sess=ses-01
```

### Project-specific script modifications (optional)

If you need to modify scripts for a specific project without affecting others:

1. **Copy the scripts directory** to your project:
   ```bash
   cp -r /home_local/Nico/fmriTools/scripts /path/to/your/project/
   ```

2. **Edit the local scripts** as needed

3. **Run make** - the Makefile automatically uses local `./scripts/` if present, otherwise uses the central scripts

This allows you to experiment with changes in one project while keeping the central pipeline intact for other projects.

### Setting up a new project

1. **Create a project directory** with your data structure

2. **Create a project-specific `conf.yaml`** with:
   - Project paths (user_folder, project_folder, data_path, programs_path)
   - Task definitions matching your experimental design
   - MRI sequence types (anatomical, functional)
   - Subject information

3. **Set the environment variables** (steps 3-4 above)

4. **Run the pipeline**

## Prerequisites

- **Tools**: FSL, AFNI, FreeSurfer, ANTs, yq (for YAML parsing)
- **Data**: DICOM files organized by subject and session
- **Configuration**: `conf.yaml` must be present in the root directory with paths and task definitions

## Project structure

Each project only needs:
- `conf.yaml`: Configuration file with paths, tasks, and MRI settings (project-specific)
- `output/`: Directory for processed data (created automatically)

The central pipeline provides:
- `Makefile`: Main build system with all preprocessing targets
- `scripts/`: Directory containing all preprocessing scripts
  - `dicomFinder.sh`: Finds and indexes DICOM folders
  - `dicom2BIDS.sh`: Converts DICOMs to BIDS NIfTI
  - `prepAnat.sh`: Performs anatomical denoising, optional resampling, and FreeSurfer segmentation
  - `sliceTiming.sh`: Applies slice timing correction using sidecar JSON files and AFNI
  - `distCorrection.sh`: Applies distortion correction using FSL's topup 
  - `motComp_anatReg.sh`: Performs motion correction and anatomical registration using AFNI and FreeSurfer
  - `projSurf.sh`: Projects data to FreeSurfer surface space
  - `prepAtlases.sh`: Prepares Benson and Wang atlas files for ROI mapping
  - `roiMapper.py`: Maps ROIs using Benson and Wang atlases for analysis
  - `boldExtractor.py`: Extracts time series from surface-projected data

## Usage

**Note**: All `make` commands must be run from the project root directory where your `conf.yaml` is located.

### Running the full pipeline

From the project root directory:

```bash
make subj=sub-01 sess=ses-01
```

This runs all steps in sequence: indexing, BIDS conversion, anatomical preprocessing, slice timing correction, distortion correction, motion correction/registration, and surface projection.

**Note on rerunning**: If a previous run failed partway through, rerunning `make subj=sub-01 sess=ses-01` will resume from the failed step without overwriting completed outputs or creating duplicates. Scripts check for existing files and skip recomputation where possible. To force a fresh start for a subject/session, run `make subj=sub-01 sess=ses-01 clean` first. Check output directories (e.g., `ls output/derivatives/`) to monitor progress.

### Running specific steps

- Index DICOMs: `make subj=sub-01 sess=ses-01 image_index`
- Convert to BIDS: `make subj=sub-01 sess=ses-01 bids`
- Anatomical preprocessing: `make subj=sub-01 sess=ses-01 anat_prep` (includes denoising with threshold 0.5 and FreeSurfer segmentation by default)
- Slice timing correction: `make subj=sub-01 sess=ses-01 slice_timing`
- Distortion correction: `make subj=sub-01 sess=ses-01 distortion_corrected`
- Motion correction: `make subj=sub-01 sess=ses-01 motion_corrected`
- Surface projection: `make subj=sub-01 sess=ses-01 surface_projected`

### Post-processing analysis steps

After completing the main preprocessing pipeline, run these analysis scripts manually:

- **Atlas preparation**: 
  ```bash
  bash /home_local/Nico/fmriTools/scripts/prepAtlases.sh <subject_id> <session_id>
  # Example: bash /home_local/Nico/fmriTools/scripts/prepAtlases.sh --subject 01 --session 01
  ```
  Generates Benson and Wang atlas files for ROI mapping. Requires FreeSurfer and neuropythy.

- **ROI mapping**: 
  ```bash
  # Activate a python environment with Neuropythy, nibabel, nilearn, etc...
  pyenv activate retMapping

  python /home_local/Nico/fmriTools/scripts/roiMapper.py --subject_id <subject_id> --session_id <session_id>
  # Example: python /home_local/Nico/fmriTools/scripts/roiMapper.py --subject_id 01 --session_id ses-01
  ```
  Maps ROIs using Benson and Wang atlases, generates flatmaps and V1 distance matrices.

- **BOLD time series extraction**:
  ```bash
  python /home_local/Nico/fmriTools/scripts/boldExtractor.py [options]
  ```
  Extracts cleaned time series from surface-projected data for specified ROIs and tasks.

### Help

Display available targets and usage:

```bash
make help
```

### Cleaning outputs

Remove all outputs for a subject/session (use with caution):

```bash
make subj=sub-01 sess=ses-01 clean
```

## Pipeline steps

1. **DICOM indexing** (`dicomFinder.sh`): Scans input folders and creates `image_index.txt` with moving/static/SBRef image paths and directions. The user can review and edit this file if needed. Tests to ensure the pipeline handles user modifications robustly are currently underway.
2. **BIDS conversion** (`dicom2BIDS.sh`): Converts DICOMs to NIfTI using dcm2niix_afni, applies BIDS naming, and generates JSON sidecars.
3. **Anatomical preprocessing** (`prepAnat.sh`): Performs MP2RAGE denoising (masking UNI with INV2, thresholding, and N4 bias correction) to produce a cleaned T1w.nii.gz. This step is optimized for 7T MP2RAGE sequences; for 3T acquisitions, the denoising method may need adjustment to match the T1 sequence type. Includes optional isotropic resampling and FreeSurfer segmentation. Can be run manually after BIDS conversion: `./scripts/prepAnat.sh sub-01 ses-01 [--segment] [--isotropic] [threshold]`. **Note**: The `make anat_prep` target runs with `--segment` by default (performing denoising and segmentation); manual runs require explicit flags.
4. **Slice timing correction** (`sliceTiming.sh`): Applies slice timing correction to account for acquisition timing differences.
5. **Distortion correction** (`distCorrection.sh`): Uses FSL's topup to correct for distortions based on AP/PA fieldmaps. Future versions will include distortion correction using ANTS for improved accuracy.
6. **Motion correction & registration** (`motComp_anatReg.sh`): Applies motion correction with AFNI's 3dvolreg, aligns runs, and registers to anatomical space using FreeSurfer's bbregister. Currently uses the default registration, which is very good. Plans exist to add an option for manual adjustment using Tkregister, as careful manual adjustment typically improves registration, especially when the field of view is not complete or more limited. **Note**: This step requires the FreeSurfer segmentation of the T1 anatomical image to be completed beforehand.
7. **Surface projection** (`projSurf.sh`): Projects volume data to FreeSurfer's cortical surface using mri_vol2surf.

## Configuration

Each project needs a `conf.yaml` file to customize:
- Paths (user_folder, project_folder, data_path, programs_path)
- Tasks (e.g., LPP1, LPP2, LOCA, REST, ML_1, ML_2, etc.)
- MRI types (anatomical, functional)
- Subject information (ID, date, demographics)

The `conf.yaml` must be in the project directory where you run `make` commands.

## Notes

- **Environment setup**: 
  - Add `FMRI_PIPELINE_HOME` to `~/.bashrc` once (persists across sessions)
  - Set `FMRI_TOOLS_HOME` and `MAKEFILES` per terminal session before running make
  - Alternatively, add these to `~/.bashrc` to make them permanent
- **Central scripts**: All preprocessing scripts are maintained in `/home_local/Nico/fmriTools/scripts/`. Edit scripts there to update all projects.
- **Local overrides**: Copy `/home_local/Nico/fmriTools/scripts` to your project to make project-specific modifications. The Makefile automatically uses local scripts if present.
- **Script priority**: Makefile checks for scripts in this order: (1) `./scripts/` (local), (2) `$FMRI_TOOLS_HOME/scripts/` (central)
- **No local Makefile needed**: The central Makefile is loaded via the `MAKEFILES` environment variable.
- The pipeline assumes FreeSurfer has been run for anatomical processing.
- Outputs are stored in `output/derivatives/` subdirectories.
- Scripts check for existing outputs and skip if already processed.
- For multiple subjects, run `make` in a loop or use a wrapper script.
- **Manual checks**: Two important manual verifications are required: (1) confirmation of the indices to the functional images during DICOM indexing, and (2) empirical establishment of a threshold for cleaning the T1 in UNI/DEN cases (default is 0.5; adjust based on visual inspection of the INV2 image to ensure proper masking without over-thresholding).
- **Pipeline scope**: This pipeline is designed for full field of view acquisitions.
- **Field strengths**: The pipeline supports both 3T and 7T acquisitions. However, the denoising method in `prepAnat.sh` is specifically designed for MP2RAGE sequences at 7T. For 3T acquisitions, the denoising step may need modification to match the T1 sequence type.
- **Segmentation**: The anatomical registration uses boundary-based registration (BBR) type.
- **Post-processing helper scripts**: After the main preprocessing pipeline, use the central scripts for ROI analysis: `prepAtlases.sh` to generate and convert Benson/Wang atlas files, `roiMapper.py` to map ROIs, compute V1 cortical distances, and create flatmaps, and `boldExtractor.py` to extract cleaned time series from surface-projected data for specified ROIs and tasks.
- **Future plans**: Adaptations for 11.7T and limited field of view are currently being considered.

## Troubleshooting

- **"No rule to make target" errors**: 
  - Check that you've set the environment variables in your current session:
    ```bash
    export FMRI_TOOLS_HOME=/home_local/Nico/fmriTools
    export MAKEFILES=$FMRI_TOOLS_HOME/Makefile
    ```
  - Verify `FMRI_PIPELINE_HOME` is in your `~/.bashrc` and reload: `source ~/.bashrc`
- **conf.yaml not found**: Make sure you're running `make` from the project directory containing `conf.yaml`.
- **Scripts not found**: 
  - Verify `/home_local/Nico/fmriTools/scripts/` exists and contains all preprocessing scripts
  - If using local scripts, ensure they're in `./scripts/` relative to your project directory
- **Wrong script version used**: Remember the Makefile uses local `./scripts/` first if present, then falls back to central scripts.
- Check that all required tools are installed and in PATH (FSL, AFNI, FreeSurfer, ANTs, yq).
- If a step fails, `make` will stop; rerun from the failed target.
- Logs are generated in output directories for debugging.

## Debugging trajectory and quick fixes

### Issue: Inconsistent DICOM naming across subjects

**Problem identified**: Scanner operators used different naming conventions across subjects:
- Some subjects: `ML-run1`, `ML-run2`, etc.
- Other subjects: `MathLang1`, `MathLang2`, etc.

This caused downstream scripts to skip tasks when manually renamed BIDS files didn't match patterns stored in `image_index.txt`.

### Solution: BIDS-native pattern detection

The pipeline was updated to automatically detect task patterns from the actual BIDS directory structure instead of relying on `image_index.txt`.

**Scripts updated**:
- `distCorrection.sh`: Now detects phase encoding directions and task patterns directly from BIDS filenames
- `motComp_anatReg.sh`: Now processes files in `conf.yaml` task order; first task becomes motion correction reference
- `sliceTiming.sh` and `projSurf.sh`: Already BIDS-compliant, no changes needed

### Task processing order

All scripts now follow the task order specified in `conf.yaml`. This is important because:
1. **Motion correction reference**: The first task's first run becomes the reference for motion correction
2. **Consistency**: All scripts process tasks in the same documented order
3. **Reproducibility**: Same order every time for the same configuration

Example from `conf.yaml`:
```yaml
Tasks:
  - ML-run1    # First task → reference for motion correction
  - ML-run2
  - ML-run3
  - ML-run4
  - ML-run5
  - LPP-run1
  - RS
```

**Processing order**: ML run-01 becomes the reference; all other runs (ML run-02 through RS) are aligned to it.

### Quick fix for future subjects with inconsistent naming

**Step 1**: Run DICOM conversion as usual:
```bash
make subj=sub-04 sess=ses-01 image_index
make subj=sub-04 sess=ses-01 bids
```

**Step 2**: If needed, manually rename files to match BIDS conventions:
```bash
cd output/sub-04/ses-01/func/

# Example: rename MathLang to ML pattern
for i in {1..5}; do
    # BOLD files
    mv "sub-04_ses-01_acq-MathLang_dir-ap_run-0${i}_epi_bold.nii.gz" \
       "sub-04_ses-01_acq-ML_dir-ap_run-0${i}_epi_bold.nii.gz"
    mv "sub-04_ses-01_acq-MathLang_dir-ap_run-0${i}_epi_bold.json" \
       "sub-04_ses-01_acq-ML_dir-ap_run-0${i}_epi_bold.json"
    
    # SBRef files
    mv "sub-04_ses-01_acq-MathLang_dir-ap_run-0${i}_SBRef.nii.gz" \
       "sub-04_ses-01_acq-ML_dir-ap_run-0${i}_SBRef.nii.gz"
    mv "sub-04_ses-01_acq-MathLang_dir-ap_run-0${i}_SBRef.json" \
       "sub-04_ses-01_acq-ML_dir-ap_run-0${i}_SBRef.json"
    
    # PA files
    mv "sub-04_ses-01_acq-MathLang_dir-pa_run-0${i}_epi.nii.gz" \
       "sub-04_ses-01_acq-ML_dir-pa_run-0${i}_epi.nii.gz"
    mv "sub-04_ses-01_acq-MathLang_dir-pa_run-0${i}_epi.json" \
       "sub-04_ses-01_acq-ML_dir-pa_run-0${i}_epi.json"
done
```

**Step 3**: Continue with the pipeline normally:
```bash
make subj=sub-04 sess=ses-01 slice_timing
make subj=sub-04 sess=ses-01 distortion_corrected
# ... or just run: make subj=sub-04 sess=ses-01
```

### Verification commands

Check if all expected files are present:
```bash
# List all acquisition patterns
ls output/sub-04/ses-01/func/*_bold.nii.gz | sed 's/.*_acq-\([^_]*\)_.*/\1/' | sort -u

# Count runs per acquisition
for acq in ML LPP RS; do
    count=$(ls output/sub-04/ses-01/func/*_acq-${acq}_*_bold.nii.gz 2>/dev/null | wc -l)
    echo "$acq: $count runs"
done
```

### Benefits of the update

- **Robust to manual corrections**: Pipeline works after renaming files
- **BIDS-compliant**: Reads directly from BIDS structure
- **Flexible**: Adapts to different naming conventions automatically
- **No reprocessing required**: If your BIDS filenames are correct, no action needed
- **Predictable reference selection**: Task order in `conf.yaml` determines motion correction reference

### Troubleshooting inconsistent naming issues

**Issue**: `distCorrection.sh` still skips some runs

**Check 1**: Verify phase encoding directions exist:
```bash
ls output/sub-04/ses-01/func/*_acq-ML_dir-ap_*.nii.gz
ls output/sub-04/ses-01/func/*_acq-ML_dir-pa_*.nii.gz
```

**Check 2**: Verify `conf.yaml` contains the pattern:
```bash
yq -r '.Tasks' conf.yaml
```

**Check 3**: Run with verbose output:
```bash
bash -x scripts/distCorrection.sh sub-04 ses-01 2>&1 | tee distcorr_debug.log
```

> This online resource is meant to be a *living document*. This means it may contain errors and corrections. New content will be added over time. Please check back regularly for the latest version.
