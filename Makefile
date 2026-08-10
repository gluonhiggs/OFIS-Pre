# Local pipeline steps. SQL runs in Snowsight; this covers everything before it.

SOURCE ?= data/raw
STAGED ?= data/staged
MIN_SEASON ?=

.PHONY: install prepare stage dry-run clean

install:
	python -m pip install -r requirements.txt

prepare:
	python scripts/prepare_data.py --source $(SOURCE) --target $(STAGED) \
		$(if $(MIN_SEASON),--min-season $(MIN_SEASON),)

dry-run:
	python scripts/load_to_stage.py --source $(STAGED) --dry-run

stage:
	python scripts/load_to_stage.py --source $(STAGED)

clean:
	rm -rf $(STAGED)
