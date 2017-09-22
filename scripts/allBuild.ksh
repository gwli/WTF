#!/bin/ksh

## allBuild.ksh
##
##  Given a WRF tarfile and target directory, this script builds WRF for various platform 
##    platforms (serial, smpar, dmpar) and build types (em_real, nmm_real, em_b_wave, em_quarter_ss). 
##
##  Author: Brian Bonnlander
##

#  getBuildString wrfType config_id
#  Returns a short string to identify with the build job.  This is used as a way to identify the type
#  of job and compiler for workflow purposes.
getBuildString()
{
   wrfType=$1
   config_id=$2
   typeCode=`getBuildCode $wrfType`
   echo "bld.${typeCode}.${config_id}"
}

#  getBuildCode buildType
#  Given a WRF build type, returns the appropriate 2-letter code identifying the build type
getBuildCode()
{
   buildType=$1
   case $buildType in
      em_real)        typeCode='er'
                      ;;
      em_real8)       typeCode='eR'
                      ;;
      nmm_real)       typeCode='nr'
                      ;;
      nmm_nest)       typeCode='nn'
                      ;;
      nmm_hwrf)       typeCode='nh'
                      ;;
      em_chem)        typeCode='ec'
                      ;;
      em_chem_kpp)    typeCode='ek'
                      ;;
      em_b_wave)      typeCode='eb'
                      ;;
      em_quarter_ss)  typeCode='eq'
                      ;;
      em_quarter_ss8) typeCode='eQ'
                      ;;
      em_hill2d_x)    typeCode='eh'
                      ;;
      em_move)        typeCode='em'
                      ;;
      wrfda_3dvar)    typeCode='3d'
                      ;;
      wrfplus)        typeCode='wp'
                      ;;
      wrfda_4dvar)    typeCode='4d'
                      ;;
                  *)  echo $0:getBuildCode:  unknown buildType $buildType
                      exit 2
                      ;;
   esac
   echo $buildType
}


if $DEBUG_WTF; then
   set -x
fi

if $BATCH_COMPILE; then
    ## From the user-specified list of WRF executables, create two lists: those that can be built in parallel (independently, all building at the same time)
    ## and those that must be built consecutively (usually relying on pre-built code, such as em_real is built first, then em_quarter_ss).
    WRF_PARALLEL=""
    WRF_SERIAL=""
    WRFDA_4DVAR=false
    for f in $BUILD_TYPES; do
       case $f in 
           em_real|em_real8|em_hill2d_x|em_move|nmm_real|nmm_nest|nmm_hwrf|em_chem|em_chem_kpp|wrfda_3dvar|wrfplus) WRF_PARALLEL="$WRF_PARALLEL $f"
	                                              ;;
           em_b_wave|em_quarter_ss|em_quarter_ss8)    WRF_SERIAL="$WRF_SERIAL $f"
	                                              ;;
           wrfda_4dvar)                               WRFDA_4DVAR=true
                                                      ;;
           *) echo "$0: unknown executable type: '$f'; aborting!"
              exit 255
       esac
    done 
else
    WRF_PARALLEL=""
    WRF_SERIAL=$BUILD_TYPES
    WRFDA_4DVAR=false
fi


wrfTarName=`basename $TARFILE .tar`

# First, fire off the builds that can be done in parallel.
for wrfType in $WRF_PARALLEL; do

   # Loop over platform choices for this WRF type. 
   # The "ni" option is the type of nesting.  The default is "1" - standard nesting.  The hill2d case is
   # built with "0" (i.e. without nesting, which is actually the entire purpose for including this ideal case in the mix).  The
   # ARW moving nest case is vortex following, and requires the nest option to be "3".
   for platform in $CONFIGURE_CHOICES; do
      buildDir=${BUILD_DIR}/$wrfTarName.$platform
      buildString=`getBuildString $wrfType $platform`
      if $BATCH_COMPILE; then
         if [[ $wrfType = "em_hill2d_x" ]]; then 
            $WRF_TEST_ROOT/scripts/buildWrf.ksh -f $TARFILE -d $buildDir -ci $platform -ct $wrfType -bs $buildString -N $NUM_PROC_BUILD -ni 0 &
         elif [[ $wrfType = "em_move" ]]; then 
            $WRF_TEST_ROOT/scripts/buildWrf.ksh -f $TARFILE -d $buildDir -ci $platform -ct $wrfType -bs $buildString -N $NUM_PROC_BUILD -ni 3 &
         else
            $WRF_TEST_ROOT/scripts/buildWrf.ksh -f $TARFILE -d $buildDir -ci $platform -ct $wrfType -bs $buildString -N $NUM_PROC_BUILD &
         fi
      else
         if [[ $wrfType = "em_hill2d_x" ]]; then 
            $WRF_TEST_ROOT/scripts/buildWrf.ksh -f $TARFILE -d $buildDir -ci $platform -ct $wrfType -bs $buildString -N $NUM_PROC_BUILD -ni 0 
         elif [[ $wrfType = "em_move" ]]; then 
            $WRF_TEST_ROOT/scripts/buildWrf.ksh -f $TARFILE -d $buildDir -ci $platform -ct $wrfType -bs $buildString -N $NUM_PROC_BUILD -ni 3 
         else
            $WRF_TEST_ROOT/scripts/buildWrf.ksh -f $TARFILE -d $buildDir -ci $platform -ct $wrfType -bs $buildString -N $NUM_PROC_BUILD
         fi
      fi
   sleep 10 # Wait 10 seconds between build jobs to avoid overloading parent job with untar and configure steps
   done
done

# Special case to speed up 4DVAR build: wait for WRFPLUS specifically, then move on
if $WRFDA_4DVAR; then
   for platform in $CONFIGURE_CHOICES; do
      batchWait $BATCH_QUEUE_TYPE "bld\.wp\.$platform" 60
      buildDir=${BUILD_DIR}/$wrfTarName.$platform
      buildString=`getBuildString wrfda_4dvar $platform`
      if $BATCH_COMPILE; then
         $WRF_TEST_ROOT/scripts/buildWrf.ksh -f $TARFILE -d $buildDir -ci $platform -ct wrfda_4dvar -bs $buildString -N $NUM_PROC_BUILD &
      else
         $WRF_TEST_ROOT/scripts/buildWrf.ksh -f $TARFILE -d $buildDir -ci $platform -ct wrfda_4dvar -bs $buildString -N $NUM_PROC_BUILD
      fi
   done
fi


# 
#  Make sure all batch jobs have been submitted, then wait for them to finish.
# 

if $BATCH_COMPILE; then
   batchWait $BATCH_QUEUE_TYPE 'bld\.' 60
fi

# Then, when all the above builds have finished, fire off the builds that cannot
# be run in parallel.   These should complete quickly, since they re-use prior WRF builds.

# Loop over WRF flavors (e.g. em_b_wave, nmm_nest, etc.)
for wrfType in $WRF_SERIAL; do
   # Loop over parallel build choices for this WRF type (e.g. serial, openmp, mpi). 
   for platform in $CONFIGURE_CHOICES; do
      buildDir=${BUILD_DIR}/$wrfTarName.$platform
      buildString=`getBuildString $wrfType $platform`
      if $BATCH_COMPILE; then
         $WRF_TEST_ROOT/scripts/buildWrf.ksh -f $TARFILE -d $buildDir -ci $platform -ct $wrfType -bs $buildString -N $NUM_PROC_BUILD &
      else
         $WRF_TEST_ROOT/scripts/buildWrf.ksh -f $TARFILE -d $buildDir -ci $platform -ct $wrfType -bs $buildString -N $NUM_PROC_BUILD 
      fi
   done
   # Wait for builds in each separate build space to finish.
   sleep 10 # Avoid potential race conditions
   if $BATCH_COMPILE; then
      for platform in $CONFIGURE_CHOICES; do
         code=`getBuildCode $wrfType`
         batchWait $BATCH_QUEUE_TYPE "bld\.${code}\.${platform}" 10
      done
   fi
done

echo ALL BUILDS APPEAR TO BE DONE!
date

#  Do not exit!   This code gets "sourced" by a parent shell, and exiting causes the parent to quit. 


