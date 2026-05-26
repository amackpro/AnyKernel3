### AnyKernel3 Ramdisk Mod Script
## osm0sis @ xda-developers

### AnyKernel setup
# begin properties
properties() { '
kernel.string=Minazuki Kernel by Amackpro
do.devicecheck=0
do.modules=0
do.systemless=1
do.cleanup=1
do.cleanuponabort=0
device.name3=
device.name4=
device.name5=
supported.versions=
supported.patchlevels=
'; } # end properties

### AnyKernel install

## boot shell variables
block=boot
is_slot_device=auto
ramdisk_compression=auto
patch_vbmeta_flag=auto

# Workaround for missing 'rev' command on some recoveries
if ! command -v rev &>/dev/null; then
  rev() {
    awk '{ for(i=length($0);i>=1;i--)printf "%s",substr($0,i,1);print "" }' "$@"
  }
fi

# import functions/variables and setup patching - see for reference (DO NOT REMOVE)
. tools/ak3-core.sh

split_boot

########## CUSTOM START ##########

BOOTMODE=false;
ps | grep zygote | grep -v grep >/dev/null && BOOTMODE=true;
$BOOTMODE || ps -A 2>/dev/null | grep zygote | grep -v grep >/dev/null && BOOTMODE=true;


extract_erofs() {
	local img_file=$1
	local out_dir=$2

	${bin}/extract.erofs -i $img_file -x -T8 -o $out_dir &> /dev/null
}

extract_vendor_boot_ramdisk() {
	local vendor_boot_img=$1
	local out_dir=$2

	mkdir -p $out_dir
	cd $out_dir
	${bin}/magiskboot unpack -h $vendor_boot_img &>/dev/null
	if [ -f ramdisk.cpio ]; then
		local comp=$(${bin}/magiskboot decompress ramdisk.cpio 2>&1 | grep -v 'raw' | sed -n 's;.*\[\(.*\)\];\1;p')
		if [ "$comp" ]; then
			mv -f ramdisk.cpio ramdisk.cpio.$comp
			${bin}/magiskboot decompress ramdisk.cpio.$comp ramdisk.cpio
		fi
		mkdir -p ramdisk
		cd ramdisk
		EXTRACT_UNSAFE_SYMLINKS=1 cpio -d -i < ../ramdisk.cpio
		cd ..
	else
		abort "! No ramdisk found in vendor_boot"
	fi
	cd $home
}

mkfs_erofs() {
	local work_dir=$1
	local out_file=$2

	local partition_name=$(basename $work_dir)

	${bin}/mkfs.erofs \
		--mount-point /${partition_name} \
		--fs-config-file ${work_dir}/../config/${partition_name}_fs_config \
		--file-contexts  ${work_dir}/../config/${partition_name}_file_contexts \
		-z lz4hc \
		$out_file $work_dir
}

is_mounted() { mount | grep -q " $1 "; }

# Check snapshot status
# Technical details: https://blog.xzr.moe/archives/30/
${bin}/snapshotupdater_static dump &>/dev/null
rc=$?
if [ "$rc" != 0 ]; then
	ui_print "Cannot get snapshot status via snapshotupdater_static! rc=$rc."
	if $BOOTMODE; then
		ui_print "If you are installing the kernel in an app, try using another app."
		ui_print "Recommend KernelFlasher:"
		ui_print "  https://github.com/capntrips/KernelFlasher/releases"
	else
		ui_print "Please try to reboot to system once before installing!"
	fi
	abort "Aborting..."
fi
snapshot_status=$(${bin}/snapshotupdater_static dump 2>/dev/null | grep '^Update state:' | awk '{print $3}')
ui_print "Current snapshot state: $snapshot_status"
if [ "$snapshot_status" != "none" ]; then
	ui_print " "
	ui_print "Seems like you just installed a rom update."
	if [ "$snapshot_status" == "merging" ]; then
		ui_print "Please use the rom for a while to wait for"
		ui_print "the system to complete the snapshot merge."
		ui_print "It's also possible to use the \"Merge Snapshots\" feature"
		ui_print "in TWRP's Advanced menu to instantly merge snapshots."
	else
		ui_print "Please try to reboot to system once before installing!"
	fi
	abort "Aborting..."
fi
unset rc snapshot_status

# Check vendor_dlkm partition status
[ -d /vendor_dlkm ] || mkdir /vendor_dlkm
is_mounted /vendor_dlkm || \
	mount /vendor_dlkm -o ro || mount /dev/block/mapper/vendor_dlkm${slot} /vendor_dlkm -o ro || \
		abort "! Failed to mount /vendor_dlkm"

strings ${home}/Image 2>/dev/null | grep -E -m1 'Linux version.*#' > ${home}/vertmp

skip_update_flag=false
do_backup_flag=false
if [ -f /vendor_dlkm/lib/modules/vertmp ]; then
	[ "$(cat /vendor_dlkm/lib/modules/vertmp)" == "$(cat ${home}/vertmp)" ] && skip_update_flag=true
else
	do_backup_flag=true
fi
umount /vendor_dlkm

# Fix unable to mount image as read-write in recovery
$BOOTMODE || setenforce 0

dd if=/dev/block/mapper/vendor_dlkm${slot} of=${home}/vendor_dlkm.img
ui_print "- It looks like you are installing Minazuki Kernel for the first time."

ui_print "- Unpacking /vendor_dlkm partition..."
extract_vendor_dlkm_dir=${home}/_extract_vendor_dlkm
mkdir -p $extract_vendor_dlkm_dir
extract_erofs ${home}/vendor_dlkm.img $extract_vendor_dlkm_dir
sync
extract_vendor_dlkm_modules_dir=${extract_vendor_dlkm_dir}/vendor_dlkm/lib/modules

ui_print "- Updating /vendor_dlkm image..."
for module in $(ls ${home}/dlkm_modules/)
do
	if [[ -f ${extract_vendor_dlkm_modules_dir}/${module} ]]; then
		ui_print "replacing $module"
		cp -f ${home}/dlkm_modules/${module} ${extract_vendor_dlkm_modules_dir}/
	else
		if [[ $module == "goodix_core.ko" ]]; then
			if [[ -f ${extract_vendor_dlkm_modules_dir}/goodix_ts.ko ]]; then
				ui_print "replacing goodix_ts.ko"
				cp -f ${home}/dlkm_modules/${module} ${extract_vendor_dlkm_modules_dir}/goodix_ts.ko
			fi
		elif [[ $module == "focaltech_touch.ko" ]]; then
			if [[ -f ${extract_vendor_dlkm_modules_dir}/focaltech_3683g.ko ]]; then
				ui_print "replacing focaltech_3683g.ko"
				cp -f ${home}/dlkm_modules/${module} ${extract_vendor_dlkm_modules_dir}/focaltech_3683g.ko
			fi
		else
			ui_print "$module not found in vendor_dlkm"
		fi
	fi
done

cp -f ${home}/vertmp ${extract_vendor_dlkm_modules_dir}/vertmp
sync

cat ${extract_vendor_dlkm_dir}/config/vendor_dlkm_fs_config | grep -q 'lib/modules/vertmp' || \
	echo 'vendor_dlkm/lib/modules/vertmp 0 0 0644' >> ${extract_vendor_dlkm_dir}/config/vendor_dlkm_fs_config

cat ${extract_vendor_dlkm_dir}/config/vendor_dlkm_file_contexts | grep -q 'lib/modules/vertmp' || \
	echo '/vendor_dlkm/lib/modules/vertmp u:object_r:vendor_file:s0' >> ${extract_vendor_dlkm_dir}/config/vendor_dlkm_file_contexts

ui_print "- Repacking /vendor_dlkm image..."
rm -f ${home}/vendor_dlkm.img

mkfs_erofs ${extract_vendor_dlkm_dir}/vendor_dlkm ${home}/vendor_dlkm.img || \
	abort "! Failed to repack the vendor_dlkm image!"

rm -rf ${extract_vendor_dlkm_dir}

unset extract_vendor_dlkm_dir extract_vendor_dlkm_modules_dir blocklist_expr

unset skip_update_flag do_backup_flag


# Flash updated /vendor_dlkm image
flash_generic vendor_dlkm

reset_ak;
echo "DEBUG: After reset_ak"


ui_print "- Dumping vendor_boot partition..."
vendor_boot_img=$home/vendor_boot.img
dd if=/dev/block/bootdevice/by-name/vendor_boot$slot of=$vendor_boot_img

ui_print "- Extracting vendor_boot ramdisk..."
extract_vendor_boot_ramdisk $vendor_boot_img $home/vendor_boot_extract

ui_print "- Replacing DTB in vendor_boot..."
unzip -o "$ZIPFILE" dtb -d "$home" >/dev/null 2>&1
if [ -f "$home/dtb" ]; then
  cp -f "$home/dtb" "$home/vendor_boot_extract/dtb"
fi

if [ -d "$home/vb_modules" ]; then
	module_path="$home/vendor_boot_extract/ramdisk/lib/modules/"
	for module in $(ls ${home}/vb_modules/)
	do
		if [[ -f ${module_path}/${module} ]]; then
			ui_print "replacing $module"
			cp -f ${home}/vb_modules/${module} ${module_path}/
		else
			if [[ $module == "goodix_core.ko" ]]; then
				if [[ -f ${module_path}/goodix_ts.ko ]]; then
					ui_print "replacing goodix_ts.ko"
					cp -f ${home}/vb_modules/${module} ${module_path}/goodix_ts.ko
				fi
			elif [[ $module == "focaltech_touch.ko" ]]; then
				if [[ -f ${module_path}/focaltech_3683g.ko ]]; then
					ui_print "replacing focaltech_3683g.ko"
					cp -f ${home}/vb_modules/${module} ${module_path}/focaltech_3683g.ko
				fi
			else
				ui_print "$module not found in vendor_boot"
			fi
		fi
	done
fi

ui_print "- Repacking vendor_boot ramdisk..."
cd $home/vendor_boot_extract/ramdisk
find . | cpio -H newc -o > ../ramdisk-new.cpio
cd $home/vendor_boot_extract

${bin}/magiskboot compress=lz4_legacy ramdisk-new.cpio ramdisk.cpio
rm -f ramdisk-new.cpio

${bin}/magiskboot repack $vendor_boot_img $home/vendor_boot_new.img 2>&1 || \
  ui_print "! Failed to repack vendor_boot"

rm -rf $home/vendor_boot_extract $vendor_boot_img $home/dtb
mv $home/vendor_boot_new.img $home/vendor_boot.img
flash_generic vendor_boot;

flash_dtbo
flash_boot
