# Makefile for BIDS-compliant preprocessing pipeline for fMRI data at both 3T and 7T field strengths. The pipeline automates the conversion, slice timing correction, distortion correction, motion correction, anatomical registration, and surface projection of DICOM data to BIDS-formatted NIfTI files, with anatomical and functional sequences configured via conf.yaml.
# Usage: make subj=sub-01 sess=ses-01 [target]
# Targets: all (default), image_index, bids, anat_prep, slice_timing, distortion_corrected, motion_corrected, surface_projected, clean, help

# Default target
.PHONY: all
all: surface_projected

# Help target
.PHONY: help
help:
	@echo "BIDS Preprocessing Pipeline Makefile"
	@echo ""
	@echo "Usage: make subj=<subject> sess=<session> [target]"
	@echo ""
	@echo "Variables:"
	@echo "  subj    Subject ID (default: sub-01)"
	@echo "  sess    Session ID (default: ses-01)"
	@echo ""
	@echo "Targets:"
	@echo "  all                 Run the full pipeline (default)"
	@echo "  image_index         Run dicomFinder.sh to create image_index.txt"
	@echo "  bids                Run dicom2BIDS.sh to convert DICOMs to BIDS NIfTI"
	@echo "  anat_prep           Run prepAnat.sh for anatomical preprocessing (denoising)"
	@echo "  slice_timing        Run sliceTiming.sh for slice timing correction"
	@echo "  distortion_corrected Run distCorrection.sh for distortion correction"
	@echo "  motion_corrected    Run motComp_anatReg.sh for motion correction and registration"
	@echo "  surface_projected   Run projSurf.sh for surface projection"
	@echo "  clean               Remove all outputs for the subject/session"
	@echo "  help                Show this help message"
	@echo ""
	@echo "Examples:"
	@echo "  make subj=sub-01 sess=ses-01"
	@echo "  make subj=sub-01 sess=ses-01 image_index"
	@echo "  make subj=sub-01 sess=ses-01 bids"
	@echo "  make help"

# Variables (override with make subj=sub-01 sess=ses-01)
subj ?= sub-01
sess ?= ses-01

# Scripts location (use local project folder if present, otherwise central repository)
FMRI_TOOLS_HOME ?= /home_local/Nico/fmriTools
SCRIPTS_DIR ?= $(shell if [ -d "./scripts" ]; then echo "./scripts"; elif [ -d "$(FMRI_TOOLS_HOME)/scripts" ]; then echo "$(FMRI_TOOLS_HOME)/scripts"; else echo "ERROR: Scripts directory not found"; exit 1; fi)

# Paths (derived from conf.yaml)
USER_FOLDER := $(shell yq -r '.Paths.user_folder' conf.yaml)
PROJECT_FOLDER := $(shell yq -r '.Paths.project_folder' conf.yaml)
BIDS_DIR := $(USER_FOLDER)$(PROJECT_FOLDER)/output
SUBJECTS_DIR := $(BIDS_DIR)/fs_subjects
FS_SUBJ := $(subj)_$(sess)_iso
BRAIN_MGZ := $(SUBJECTS_DIR)/$(FS_SUBJ)/mri/brain.mgz
IMAGE_INDEX := $(BIDS_DIR)/$(subj)/$(sess)/image_index.txt
BIDS_FUNC := $(BIDS_DIR)/$(subj)/$(sess)/func
SLICE_TIMING_DIR := $(BIDS_DIR)/derivatives/slice-timing-corrected/$(subj)/$(sess)
SLICE_TIMING_FILES := $(shell find $(SLICE_TIMING_DIR)/func -name "*_desc-stc_bold.nii.gz" 2>/dev/null | head -1)
DIST_CORR_FILES := $(shell find $(BIDS_DIR)/derivatives/distortion-corrected/$(subj)/$(sess)/func -name "*_desc-dc_bold.nii.gz" 2>/dev/null | head -1)
MOT_CORR_FILES := $(shell find $(BIDS_DIR)/derivatives/motion-compensated/$(subj)/$(sess)/func -name "*_desc-coreg_bold.nii.gz" 2>/dev/null | head -1)
SURF_FILES := $(shell find $(BIDS_DIR)/derivatives/surf-projected/$(subj)/$(sess)/func -name "lh.*_desc-surf.mgh" 2>/dev/null | head -1)

# Target 1: Run dicomFinder.sh to create image_index.txt
image_index: $(SCRIPTS_DIR)/dicomFinder.sh
	@echo "Running dicomFinder.sh for $(subj) $(sess)..."
	$(SCRIPTS_DIR)/dicomFinder.sh $(subj) $(sess)
	@if [ ! -f "$(IMAGE_INDEX)" ]; then echo "ERROR: image_index.txt not created"; exit 1; fi

# Target 2: Run dicom2BIDS.sh to convert DICOMs to BIDS NIfTI
bids: $(IMAGE_INDEX) $(SCRIPTS_DIR)/dicom2BIDS.sh $(BIDS_DIR)/$(subj)/$(sess)/.bids_done

$(IMAGE_INDEX):
	@echo "ERROR: image_index.txt not found at $(IMAGE_INDEX)"
	@echo "Run 'make subj=$(subj) sess=$(sess) image_index' first to create it."
	@echo "Then edit it manually if needed before running 'make bids'."
	@exit 1

$(BIDS_DIR)/$(subj)/$(sess)/.bids_done: $(SCRIPTS_DIR)/dicom2BIDS.sh $(IMAGE_INDEX)
	@echo "Running dicom2BIDS.sh for $(subj) $(sess)..."
	$(SCRIPTS_DIR)/dicom2BIDS.sh $(subj) $(sess)
	@if [ ! -d "$(BIDS_FUNC)" ] || [ -z "$$(find $(BIDS_FUNC) -name "*.nii.gz" 2>/dev/null)" ]; then echo "ERROR: BIDS func files not created"; exit 1; fi
	@touch $(BIDS_DIR)/$(subj)/$(sess)/.bids_done

# Target 2.5: Run prepAnat.sh for anatomical preprocessing (denoising, optional segmentation)
anat_prep: bids $(BIDS_DIR)/$(subj)/$(sess)/.anat_prep_done

$(BIDS_DIR)/$(subj)/$(sess)/.anat_prep_done:
	@echo "Running prepAnat.sh for $(subj) $(sess) with --segment and default threshold 0.5..."
	$(SCRIPTS_DIR)/prepAnat.sh $(subj) $(sess) --segment
	@if [ ! -f "$(BIDS_DIR)/$(subj)/$(sess)/anat/$(subj)_$(sess)_T1w.nii.gz" ]; then \
		echo "ERROR: Anatomical preprocessing failed - T1w.nii.gz not created"; \
		exit 1; \
	fi
	@if [ ! -d "$(SUBJECTS_DIR)/$(FS_SUBJ)" ]; then \
		echo "ERROR: FreeSurfer segmentation failed - $(SUBJECTS_DIR)/$(FS_SUBJ) not created"; \
		exit 1; \
	fi
	@touch $(BIDS_DIR)/$(subj)/$(sess)/.anat_prep_done
	@echo "Anatomical preprocessing completed for $(subj) $(sess)"

# Target 3: Run sliceTiming.sh for slice timing correction
slice_timing: anat_prep $(SCRIPTS_DIR)/sliceTiming.sh
	@if [ ! -d "$(BIDS_FUNC)" ]; then \
		echo "ERROR: BIDS func directory not found at $(BIDS_FUNC). Run 'make subj=$(subj) sess=$(sess) bids' first."; \
		exit 1; \
	fi
	@echo "Running sliceTiming.sh for $(subj) $(sess)..."
	$(SCRIPTS_DIR)/sliceTiming.sh $(subj) $(sess)
	@if [ -z "$$(find $(SLICE_TIMING_DIR)/func -name "*desc-stc_bold.nii.gz" 2>/dev/null | head -1)" ]; then \
		echo "ERROR: Slice-timing corrected files not created in $(SLICE_TIMING_DIR)/func. Check sliceTiming.sh output."; \
		exit 1; \
	fi
	@echo "Slice timing correction completed successfully."

# Target 3: Run distCorrection.sh for distortion correction
distortion_corrected: slice_timing $(SCRIPTS_DIR)/distCorrection.sh
	@if [ ! -f "$(IMAGE_INDEX)" ]; then echo "ERROR: image_index.txt not found at $(IMAGE_INDEX). Run 'make subj=$(subj) sess=$(sess) image_index' first."; exit 1; fi
	@echo "Running distCorrection.sh for $(subj) $(sess)..."
	$(SCRIPTS_DIR)/distCorrection.sh $(subj) $(sess)
	@if [ -z "$$(find $(BIDS_DIR)/derivatives/distortion-corrected/$(subj)/$(sess)/func -name "*_desc-dc_bold.nii.gz" 2>/dev/null | head -1)" ]; then echo "ERROR: Distortion-corrected files not created"; exit 1; fi

# Target 4: Run motComp_anatReg.sh for motion correction and registration
motion_corrected: distortion_corrected $(SCRIPTS_DIR)/motComp_anatReg.sh
	@if [ ! -d "$(SUBJECTS_DIR)/$(FS_SUBJ)" ]; then echo "ERROR: FreeSurfer subject directory $(SUBJECTS_DIR)/$(FS_SUBJ) does not exist. Please ensure FreeSurfer recon-all has been run for this subject."; exit 1; fi
	@if [ ! -f "$(BRAIN_MGZ)" ]; then echo "ERROR: FreeSurfer brain.mgz not found at $(BRAIN_MGZ). Please ensure FreeSurfer segmentation (recon-all) is completed for this subject."; exit 1; fi
	@echo "Running motComp_anatReg.sh for $(subj) $(sess)..."
	$(SCRIPTS_DIR)/motComp_anatReg.sh $(subj) $(sess)
	@if [ -z "$$(find $(BIDS_DIR)/derivatives/motion-compensated/$(subj)/$(sess)/func -type f -name "*_desc-coreg_bold.nii.gz" 2>/dev/null | head -1)" ]; then \
		echo "WARNING: No motion-corrected files created for $(subj) $(sess)"; \
	else \
		echo "Motion correction completed successfully for $(subj) $(sess)"; \
	fi

# Target 5: Run projSurf.sh for surface projection
surface_projected: motion_corrected $(SCRIPTS_DIR)/projSurf.sh $(BIDS_DIR)/derivatives/surf-projected/$(subj)/$(sess)/.surf_proj_done

$(BIDS_DIR)/derivatives/surf-projected/$(subj)/$(sess)/.surf_proj_done: $(SCRIPTS_DIR)/projSurf.sh
	@echo "Running projSurf.sh for $(subj) $(sess)..."
	$(SCRIPTS_DIR)/projSurf.sh $(subj) $(sess)
	@touch $(BIDS_DIR)/derivatives/surf-projected/$(subj)/$(sess)/.surf_proj_done

# Clean target: Remove all outputs (use with caution)
.PHONY: clean
clean:
	@echo "Cleaning outputs for $(subj) $(sess)..."
	@echo "Delete slice-timing-corrected? (y/n)"
	@read -p "" confirm; if [ "$$confirm" = "y" ]; then rm -rf $(BIDS_DIR)/derivatives/slice-timing-corrected/$(subj)/$(sess); echo "Deleted $(BIDS_DIR)/derivatives/slice-timing-corrected/$(subj)/$(sess)"; else echo "Skipped."; fi
	@echo "Delete distortion-corrected? (y/n)"
	@read -p "" confirm; if [ "$$confirm" = "y" ]; then rm -rf $(BIDS_DIR)/derivatives/distortion-corrected/$(subj)/$(sess); echo "Deleted $(BIDS_DIR)/derivatives/distortion-corrected/$(subj)/$(sess)"; else echo "Skipped."; fi
	@echo "Delete motion-compensated? (y/n)"
	@read -p "" confirm; if [ "$$confirm" = "y" ]; then rm -rf $(BIDS_DIR)/derivatives/motion-compensated/$(subj)/$(sess); echo "Deleted $(BIDS_DIR)/derivatives/motion-compensated/$(subj)/$(sess)"; else echo "Skipped."; fi
	@echo "Delete surf-projected? (y/n)"
	@read -p "" confirm; if [ "$$confirm" = "y" ]; then rm -rf $(BIDS_DIR)/derivatives/surf-projected/$(subj)/$(sess); echo "Deleted $(BIDS_DIR)/derivatives/surf-projected/$(subj)/$(sess)"; else echo "Skipped."; fi
	@echo "Delete FreeSurfer subject directory? (y/n)"
	@read -p "" confirm; if [ "$$confirm" = "y" ]; then rm -rf $(SUBJECTS_DIR)/$(FS_SUBJ); echo "Deleted $(SUBJECTS_DIR)/$(FS_SUBJ)"; else echo "Skipped."; fi
	@echo "Delete BIDS subject directory $(BIDS_DIR)/$(subj)? (y/n) WARNING: This contains BIDS-formatted data! Delete only if you have access to the DICOM files and know what you are doing."
	@read -p "" confirm; if [ "$$confirm" = "y" ]; then rm -rf $(BIDS_DIR)/$(subj); echo "Deleted $(BIDS_DIR)/$(subj)"; else echo "Skipped."; fi