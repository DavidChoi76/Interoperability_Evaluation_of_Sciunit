#!/bin/bash
##################################################################################
# 1. Set name, parameters and raw model input
PROJDIR="." # full path to the project location;
RHESSysNAME='Coweeta_Sub18' # e.g., rhessys_baisman10m
EPSGCODE='EPSG:26917' # need to (manually) lookup the EPSG code for NAD83 UTM ##N for the catchment
RESOLUTION=10 #spatial resolution (meters) of the grids
expectedDrainageArea=125700 # meter squre
downloadedDEMfile="$PROJDIR"/"$RHESSysNAME"/gis_data/DEM.tif
downloadedLULCfile="$PROJDIR"/"$RHESSysNAME"/gis_data/NLCD.tif
downloadedSSURGOdirectoryPATH="$PROJDIR"/"$RHESSysNAME"/gis_data/wss_aoi
downloadedSSURGOshape="$downloadedSSURGOdirectoryPATH"/spatial/soilmu_a_aoi.shp
GITHUBLIBRARIES="https://raw.githubusercontent.com/DavidChoi76/pyrhessys/master/pyrhessys"
##################################################################################
# 2. Create RHESSys folder structures
mkdir "$PROJDIR"/"$RHESSysNAME"
mkdir "$PROJDIR"/"$RHESSysNAME"/model/defs
mkdir "$PROJDIR"/"$RHESSysNAME"/model/flows
mkdir "$PROJDIR"/"$RHESSysNAME"/model/worldfiles
mkdir "$PROJDIR"/"$RHESSysNAME"/model/clim
mkdir "$PROJDIR"/"$RHESSysNAME"/model/tecfiles
mkdir "$PROJDIR"/"$RHESSysNAME"/model/output
mkdir "$IMAGE"
##################################################################################
# 3. Setup GRASS dataset
GISDBASE="$RHESSysNAME"/grass_dataset
LOCATION_NAME="$RHESSysNAME"
LOCATION="$GISDBASE"/$LOCATION_NAME
MAPSET=PERMANENT
grassCMD='grass'
mkdir "$PROJDIR"/"$RHESSysNAME"/grass_dataset # does not overwrite
$grassCMD -c $EPSGCODE -e "$LOCATION" 
##################################################################################
# 4. Import DEM
$grassCMD "$LOCATION"/$MAPSET --exec r.in.gdal -e --overwrite input="$downloadedDEMfile" output=demRAW location=elevationRAW
LOCATIONDEM="$GISDBASE"/elevationRAW
$grassCMD "$LOCATIONDEM"/$MAPSET --exec g.region raster=demRAW
$grassCMD "$LOCATIONDEM"/$MAPSET --exec g.region res=$RESOLUTION -a -p
$grassCMD "$LOCATIONDEM"/$MAPSET --exec r.resamp.stats -w input=demRAW output=dem$RESOLUTION'm' ### skip this if no resampling spatial scale
$grassCMD "$LOCATIONDEM"/$MAPSET --exec r.out.gdal --overwrite input=dem$RESOLUTION'm' output="$PROJDIR"/"$RHESSysNAME"/gis_data/dem$RESOLUTION'm.tif' format=GTiff
### ... import the (rescaled) elevation data into ""$LOCATION"/$MAPSET"
$grassCMD "$LOCATION"/$MAPSET --exec r.in.gdal -o -e --overwrite input="$PROJDIR"/"$RHESSysNAME"/gis_data/dem$RESOLUTION'm.tif' output=dem
$grassCMD "$LOCATION"/$MAPSET --exec g.region raster=dem
rm -rf "$LOCATIONDEM"
##################################################################################
# 5. Create Watershed Outlet
$grassCMD "$LOCATION"/$MAPSET --exec v.in.ascii input='gage_latlon.txt' output=outlet separator=space
##################################################################################
# 6. Delineate Watershed
expectedThresholdModelStr=$(($expectedDrainageArea/20)) # meter sq. # note to include Pond Branch as a channel; 390*900=351000
expectedThresholdStrExt=$(($expectedDrainageArea/100)) # meter sq.
GRASS_thres=$(($expectedThresholdModelStr/$RESOLUTION/$RESOLUTION)) # grid cell for stream network and hillslope configuration
GRASS_thresII=$(($expectedThresholdStrExt/$RESOLUTION/$RESOLUTION))
GRASS_drainarea_lowerbound=$((98*$expectedDrainageArea/$RESOLUTION/$RESOLUTION/100)) # (allow 2% error)
GRASS_drainarea_upperbound=$((102*$expectedDrainageArea/$RESOLUTION/$RESOLUTION/100)) # (allow 2% error)
curl -s "$GITHUBLIBRARIES"/sh_code/grass_delineation_dinf.sh | $grassCMD "$LOCATION"/"$MAPSET" --exec bash -s $GRASS_thres $GRASS_drainarea_lowerbound $GRASS_drainarea_upperbound
curl -s "$GITHUBLIBRARIES"/r_code/basin_extraction.R | $grassCMD "$LOCATION"/"$MAPSET" --exec R --slave
$grassCMD "$LOCATION"/"$MAPSET" --exec r.watershed elevation=dem threshold=$GRASS_thresII stream=strExt --overwrite # full stream extension;
curl -s "$GITHUBLIBRARIES"/sh_code/grass_spatial_hierarchy.sh | $grassCMD "$LOCATION"/"$MAPSET" --exec bash -s
##################################################################################
# 7. Create Zone for Climate area
curl -s "$GITHUBLIBRARIES"/r_code/zone_cluster.R | $grassCMD "$LOCATION"/"$MAPSET" --exec R --slave --args dem slope aspect hill zone_cluster
##################################################################################
# 8. Create isohyet for precipitation distribution
$grassCMD "$LOCATION"/$MAPSET --exec r.in.gdal -o --overwrite input="$PROJDIR"/"$RHESSysNAME"/gis_data/isohyet.tif output=isohyet
##################################################################################
# 9. Extract Soil attributes
$grassCMD "$LOCATION"/$MAPSET --exec v.in.ogr --overwrite input="$downloadedSSURGOshape" output=ssurgo location=soilRAW
LOCATIONSOIL="$GISDBASE"/soilRAW
$grassCMD "$LOCATION"/$MAPSET --exec v.proj --overwrite location=soilRAW mapset=PERMANENT input=ssurgo output=ssurgo
$grassCMD "$LOCATION"/$MAPSET --exec v.to.rast --overwrite input=ssurgo use=cat output=soil_ssurgo
$grassCMD "$LOCATION"/$MAPSET --exec v.out.ascii --overwrite input=ssurgo type=centroid output="$PROJDIR"/"$RHESSysNAME"/model/soil_cat_mukey.csv columns=MUKEY format=point separator=comma
curl -s "$GITHUBLIBRARIES"/r_code/ssurgo_extraction.R | $grassCMD "$LOCATION"/$MAPSET --exec R  --slave --args "$downloadedSSURGOdirectoryPATH"
curl -s "$GITHUBLIBRARIES"/r_code/ssurgo_soiltexture2gis.R | $grassCMD "$LOCATION"/$MAPSET --exec R --slave --args "$PROJDIR"/"$RHESSysNAME"/model/soil_cat_mukey.csv "$downloadedSSURGOdirectoryPATH"/soil_mukey_texture.csv
rm -rf "$LOCATIONSOIL"
##################################################################################
# 10. Extract NLCD attributes
$grassCMD "$LOCATION"/$MAPSET --exec r.in.gdal -e --overwrite input="$downloadedLULCfile" output=lulcRAW location=lulcRAW
LOCATIONLULC="$GISDBASE"/lulcRAW
$grassCMD "$LOCATION"/$MAPSET --exec r.to.vect --overwrite input=patch output=patch type=area
$grassCMD "$LOCATIONLULC"/$MAPSET --exec v.proj location=$LOCATION_NAME mapset=$MAPSET input=patch output=patch$RESOLUTION'm'
$grassCMD "$LOCATIONLULC"/$MAPSET --exec v.to.rast input=patch$RESOLUTION'm' output=patch$RESOLUTION'm' use=attr attribute_column=value
$grassCMD "$LOCATIONLULC"/"$MAPSET" --exec g.region zoom=patch$RESOLUTION'm'
curl -s "$GITHUBLIBRARIES"/r_code/patch_lulc_extraction.R | $grassCMD "$LOCATIONLULC"/"$MAPSET" --exec R --slave --args patch$RESOLUTION'm' lulcRAW "$PROJDIR"/"$RHESSysNAME"/model/lulcFrac$RESOLUTION'm.csv'
curl -o lulc_forest_fraction.csv "$GITHUBLIBRARIES"/meta/lulc_forest_fraction.csv
curl -s "$GITHUBLIBRARIES"/r_code/lulcFrac_write2gis.R | $grassCMD "$LOCATION"/"$MAPSET" --exec R --slave --args patch "$PROJDIR"/"$RHESSysNAME"/model/lulcFrac$RESOLUTION'm.csv' lulc_forest_fraction.csv
rm -rf "$LOCATIONLULC"
##################################################################################
# 11. Create Landuse Fraction
$grassCMD "$LOCATION"/$MAPSET --exec r.in.gdal -o --overwrite input="$downloadedLULCfile" output=nlcd
$grassCMD "$LOCATION"/$MAPSET --exec r.mapcalc --overwrite expression="evergreen = if(forestFrac>0&&(nlcd==42||nlcd==43),1,null())"
$grassCMD "$LOCATION"/$MAPSET --exec r.mapcalc --overwrite expression="evergreen_FFrac = if(forestFrac>0,if(nlcd==42,1.0,if(nlcd==43,0.5,null())),null())"
$grassCMD "$LOCATION"/$MAPSET --exec r.mapcalc --overwrite expression="evergreen_LAI = if(forestFrac>0,if(nlcd==42,5.0,if(nlcd==43,3.5,null())),null())"
$grassCMD "$LOCATION"/$MAPSET --exec r.mapcalc --overwrite expression="deciduous = if(forestFrac>0&&(nlcd==41||nlcd==43),2,null())"
$grassCMD "$LOCATION"/$MAPSET --exec r.mapcalc --overwrite expression="deciduous_FFrac = if(forestFrac>0,if(nlcd==41,1.0,if(nlcd==43,0.5,null())),null())"
$grassCMD "$LOCATION"/$MAPSET --exec r.mapcalc --overwrite expression="deciduous_LAI = if(forestFrac>0,if(nlcd==41,4.5,if(nlcd==43,3.0,null())),null())"
##################################################################################
# 12. Create Template 
templateFile="$PROJDIR"/"$RHESSysNAME"/model/g2w_template.txt
# set paths for RHESSys input files
#...1 = Yes, output this file; 0 = No, do not output this file
echo projdir \""$PROJDIR"/"$RHESSysNAME"\" > "$templateFile"
echo outputWorldfile "$PROJDIR"/"$RHESSysNAME"/model/worldfiles/worldfile.csv 1 >> $templateFile
echo outputWorldfileHDR "$PROJDIR"/"$RHESSysNAME"/model/worldfiles/worldfile.hdr 1 >> $templateFile
echo outputDefs "$PROJDIR"/"$RHESSysNAME"/model/defs 1 >> $templateFile
echo outputSurfFlow "$PROJDIR"/"$RHESSysNAME"/model/flows/surfflow.txt 1 >> $templateFile
echo outputSubFlow "$PROJDIR"/"$RHESSysNAME"/model/flows/subflow.txt 1 >> $templateFile
echo vegCollection \"https://raw.githubusercontent.com/DavidChoi76/pyrhessys/master/pyrhessys/meta/vegCollection.csv\" >> "$templateFile"
echo soilCollection \"https://raw.githubusercontent.com/DavidChoi76/pyrhessys/master/pyrhessys/meta/soilCollection.csv\" >> "$templateFile"
echo lulcCollection \"https://raw.githubusercontent.com/DavidChoi76/pyrhessys/master/pyrhessys/meta/lulcCollectionEC.csv\" >> "$templateFile"
#...set climate station ID and file name
echo stationID 101 >> $templateFile
echo stationFile \"clim/cwt.base\" >> $templateFile
#...the following maps that must be provided with syntex:
#...echo keyword <map> >> "$templateFile"
echo basinMap basin >> $templateFile
echo hillslopeMap hill >> $templateFile
echo zoneMAP zone_cluster >> $templateFile
echo patchMAP patch >> $templateFile
echo soilidMAP soil_ssurgo >> $templateFile
echo soiltexture soil_texture >> $templateFile
echo xMAP xmap >> $templateFile
echo yMAP ymap >> $templateFile
echo demMAP dem >> $templateFile
echo slopeMap slope >> $templateFile
echo aspectMAP aspect >> $templateFile
echo twiMAP wetness_index >> $templateFile
echo whorizonMAP west_180 >> $templateFile
echo ehorizonMAP east_000 >> $templateFile
echo isohyetMAP isohyet >> $templateFile
echo rowMap rowmap >> $templateFile
echo colMap colmap >> $templateFile
echo drainMap drain >> $templateFile
#...impervious and its breakdown
echo impFracMAP impFrac >> "$templateFile"
echo roofMAP roofFrac >> "$templateFile"
echo drivewayMAP drivewayFrac >> "$templateFile"
echo pavedRoadFracMAP pavedRoadFrac >> "$templateFile"
#...forest vegetations
echo forestFracMAP forestFrac >> "$templateFile"
echo tree1StratumID deciduous >> "$templateFile"
echo tree1FFrac deciduous_FFrac >> "$templateFile"
echo tree1LAI deciduous_LAI >> "$templateFile"
echo tree2StratumID evergreen >> "$templateFile"
echo tree2FFrac evergreen_FFrac >> "$templateFile"
echo tree2LAI evergreen_LAI >> "$templateFile"
#...shrub vegetation
echo shrubFracMAP shrubFrac >> "$templateFile"
#...crop vegetation
echo cropFracMAP cropFrac >> "$templateFile"
#...lawn/pasture vegetation
echo grassFracMAP lawnFrac >> "$templateFile"
#...modeling stream-grids
echo streamMap str >> "$templateFile"
# The following maps are optional; User can comment out the lines that do not apply using "#" up front.
echo streamFullExtension strExt >> "$templateFile"
##################################################################################
# 13. Create worldfile, definition file, and flow file
curl -o LIB_misc.R https://raw.githubusercontent.com/DavidChoi76/pyrhessys/master/pyrhessys/r_code/LIB_misc.R
curl -s "$GITHUBLIBRARIES"/r_code/g2world_def_flow_git.R | $grassCMD "$LOCATION"/$MAPSET --exec R --slave --args "$templateFile"
curl -s "$GITHUBLIBRARIES"/r_code/g2world.R | R --slave --args na "$PROJDIR"/"$RHESSysNAME"/model/worldfiles/worldfile.csv "$PROJDIR"/"$RHESSysNAME"/model/worldfiles/worldfile