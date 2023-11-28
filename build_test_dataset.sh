#! /usr/bin/env bash

# Build test dataset from two .osm.pbf files
# * one OSM extract covering a small area (e.g. a country or state)
# * one OSM extract covering a larger area (e.g. a continent)
#
# The large extract is used generate vector tiles on zoom levels 0 to 7. It
# is filtered using osmium tags-filter in order to reduce the memory consumption.
#
# The small extract is used for zoom level 8 to 14.
#
# If tilemaker and osmium are not in your $PATH, you have to provide their pathes using
# the environment variables TILEMAKER and OSMIUM.

set -euo pipefail

function create_output_dir {
    NAME=$1
    TYPE=$2
    if [ "$TYPE" = "files" ]; then
        mkdir $NAME
    fi
}

function output_path {
    NAME=$1
    TYPE=$2
    if [ "$TYPE" = "files" ]; then
        echo $NAME
        return
    fi
    echo ${NAME}.mbtiles
}

TILEMAKER=${TILEMAKER:-tilemaker}
OSMIUM=${OSMIUM:-osmium}

if [ "$#" -lt 6 ]; then
    echo "ERROR: Wrong Usage"
    echo "Usage: $0 OUTPUT_FORMAT BBOX SMALL_OSM_PBF LARGE_OSM_PBF TMP_DIR OUT_DIR_OR_FILE [TILEMAKER_EXTRA_ARGS]"
    exit 1
fi

OUTPUT_FORMAT=$1
shift
BBOX=$1
shift
SMALL_OSM_PBF=$1
shift
LARGE_OSM_PBF=$1
shift
TMP_DIR=$1
shift
OUT_DIR=$1
shift

if [ ! -d "$TMP_DIR" ]; then
    echo "ERROR: Temporary directory $TMP_DIR does not exist."
    exit 1
fi
if [ $OUTPUT_FORMAT = "files" ] && [ ! -d "$OUT_DIR" ]; then
    echo "ERROR: Output directory $OUT_DIR does not exist."
    exit 1
fi
if [ $OUTPUT_FORMAT = "mbtiles" ] && [ ! -d $(dirname "$OUT_DIR") ]; then
    echo "ERROR: Parent directory of output file $OUT_DIR does not exist."
    exit 1
fi
if [ "$OUTPUT_FORMAT" != "files" ] && [ "$OUTPUT_FORMAT" != "mbtiles" ] ; then
    echo "ERROR: Unknown output format provided."
    exit 1
fi

EXTRA_ARGS=$@
echo "Make small region."
SMALL_NAME=$(output_path $TMP_DIR/small $OUTPUT_FORMAT)
create_output_dir $SMALL_NAME $OUTPUT_FORMAT
echo "$TILEMAKER" $EXTRA_ARGS --input $SMALL_OSM_PBF --output $SMALL_NAME --config config.json --process process.lua
"$TILEMAKER" $EXTRA_ARGS --input $SMALL_OSM_PBF --output $SMALL_NAME --config config.json --process process.lua

echo "Make large region."
LARGE_OSM_PBF_FILTERED=$(mktemp --suffix .osm.pbf)
"$OSMIUM" tags-filter --overwrite -o $LARGE_OSM_PBF_FILTERED --progress $LARGE_OSM_PBF n/place r/admin_level=2 r/admin_level=4 w/waterway w/highway=motorway w/highway=motorway_link w/highway=trunk w/highway=trunk_link wr/natural=water wr/waterway=riverbank wr/landuse=basin wr/landuse=reservoir wr/natural=glacier wr/waterway=dock wr/waterway=canal wr/landuse=forest
jq '.settings.maxzoom |= 7' config.json > config-lowzoom.json
LARGE_NAME=$(output_path $TMP_DIR/large $OUTPUT_FORMAT)
create_output_dir $LARGE_NAME $OUTPUT_FORMAT
"$TILEMAKER" $EXTRA_ARGS --bbox=$BBOX --input "$LARGE_OSM_PBF_FILTERED" --output "$LARGE_NAME" --config config-lowzoom.json --process process.lua
rm $LARGE_OSM_PBF_FILTERED

if [ "$OUTPUT_FORMAT" = "mbtiles" ]; then
    echo "Merging MBTiles"
    sqlite3 $SMALL_NAME "ATTACH DATABASE '$LARGE_NAME' AS large; BEGIN; DELETE FROM tiles WHERE zoom_level <= 7; INSERT INTO tiles (zoom_level, tile_column, tile_row, tile_data) SELECT zoom_level, tile_column, tile_row, tile_data FROM large.tiles; UPDATE metadata AS mm SET value = m.value FROM large.metadata AS m WHERE m.name = mm.name; COMMIT; DETACH DATABASE large;"
    rm "$LARGE_NAME"
    mv $SMALL_NAME $OUT_DIR
    echo "Result written to $OUT_DIR"
    exit 0
fi

echo "Merging"
rsync -a "$LARGE_NAME/" "$SMALL_NAME/"
TMPFILE=$(mktemp)
jq '.maxzoom=14' "$SMALL_NAME/metadata.json" > "$TMPFILE"
mv "$TMPFILE" "$SMALL_NAME/metadata.json"

echo "Setting correct maxzoom in metadata.json"
TMPFILE=$(mktemp)
jq '.maxzoom=14' "$SMALL_NAME/metadata.json" > $TMPFILE
chmod --reference="$SMALL_NAME/metadata.json" $TMPFILE
chown --reference="$SMALL_NAME/metadata.json" $TMPFILE
mv $TMPFILE "$SMALL_NAME/metadata.json"

echo "Result written to $OUT_DIR"
