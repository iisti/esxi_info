#!/usr/bin/env bash

# Scripted by Juho Itä 31.5.2020

# This script collects information from ESXi servers.
# Information is collected by running built-in functions of ESXi via
# SSH and then transferring the results via SCP to the server run by this
# script.

# Version history
#   0.1   Initial script, re-written from older script.
#   0.2   vm process list and getallvms are formatted nicely and memory stats
#         are retrieved with vsish command instead of performance gathering. 
script_version="0.2"

###### FUNCTIONS ######

# Retrieve from which folder the script is run
# Source: https://stackoverflow.com/questions/59895/get-the-source-directory-of-a-bash-script-from-within-the-script-itself
func_get_script_source_dir () {
    SOURCE="${BASH_SOURCE[0]}"
    while [ -h "$SOURCE" ]; do # resolve $SOURCE until the file is no longer a symlink
        DIR="$( cd -P "$( dirname "$SOURCE" )" >/dev/null 2>&1 && pwd )"
        SOURCE="$(readlink "$SOURCE")"
        # if $SOURCE was a relative symlink, we need to resolve it relative
        # to the path where the symlink file was located
        [[ $SOURCE != /* ]] && SOURCE="$DIR/$SOURCE"
    done
    local DIR="$( cd -P "$( dirname "$SOURCE" )" >/dev/null 2>&1 && pwd )"
    echo $DIR
}

# Function with a script which is run on ESXis for generating information
# Syntax example: https://stackoverflow.com/a/3872762/3498768
func_run_esxi_script () {
esxi="$1"
ssh -i "$ssh_key" root@"$esxi" "ash -s" <<'EOF'
#!/bin/sh

# Temp output directory
output_dir="/tmp/random-stuff/"

echo "Create directory for the information /tmp/random-stuff/"
mkdir -p $output_dir

echo "Checking date"
date > $output_dir/date.txt
date +%s > $output_dir/date_secs.txt

echo "Checking hostname"
host_name=$(hostname | cut -d "." -f1)
echo $host_name > $output_dir/hostname.txt

echo "Checking ESXi version"
vmware -vl > $output_dir/esxi_version.txt

echo "Checking Management Network information"
esxcli network ip interface ipv4 get > $output_dir/ip_addr.txt

# The memory checking with vsish is much more faster than extracting
# performance information.
#
#echo "Checking performance information for extracting memory information"
#esxtop -b -n 1 > $output_dir/perf.csv

echo "Checking memory information"
vsish -e get /memory/comprehensive > $output_dir/memory_vsish.txt

echo  "Checking storage usage"
df -h > $output_dir/storage_usage.txt

echo "Checking datastore information"
for esxi_storage in /vmfs/volumes/*; do
    if [ -L "$esxi_storage" ]; then
        # $f is a symlink
        echo "    Found: $esxi_storage"
        # Save storage name without the whole path
        storage_name=$(echo "$esxi_storage" | sed 's|.*/||')
        echo "ls -l $esxi_storage/" > "$output_dir"/storage_ls_"$storage_name".txt
        ls -l "$esxi_storage"/ >> "$output_dir"/storage_ls_"$storage_name".txt
    fi
done

echo "Checking filesystems"
esxcli storage filesystem list > $output_dir/filesystem_list.txt

echo "Checking all registered VMs"
vim-cmd vmsvc/getallvms > $output_dir/getallvms.txt

echo "Checking all running VMs"
esxcli vm process list > $output_dir/esxcli-vm-process-list.txt
EOF

}

# THIS IS OBSOLETE vsish is more efficient
# Export total ESXi server memory and free ESXi server memory to file memory.txt
func_extract_memory_usage () {

mem_output="$esxi_info_path/$esxi/memory.txt"

printf "Total Memory: " > $mem_output

# tr "," "\12" = translate commas to line feeds
line_overall_mem="$(head -1 $esxi_info_path/$esxi/perf.csv | tr "," "\12" | grep -in "Machine MBytes" | cut -d ":" -f1)"; \

tail -1 $esxi_info_path/$esxi/perf.csv | tr "," "\12" | sed -n "${line_overall_mem}p" | sed 's/"//g' >> $mem_output

printf "Free Memory: " >> $mem_output

line_free_mem="$(head -1 $esxi_info_path/$esxi/perf.csv | tr "," "\12" | grep -in 'Memory\\Free MBytes' | cut -d ":" -f1)"; \

tail -1 $esxi_info_path/$esxi/perf.csv | tr "," "\12" | sed -n "${line_free_mem}p" | sed 's/"//g' >> $mem_output

# Print memory usage
cat $esxi_info_path/$esxi/memory.txt >> $index_html
}

# For pretty printing of getallvms. The default ESXi print can be quite hard to
# read because of text layout is garbled.
func_print_getallvms () {

file="$1"
readarray -t arr < "$file"

for i in "${arr[@]}"
do
  # The printing of Annonation/Notes of the VM start from the same line as
  # the vmid, Name, File, Guest OS, Version, Annonation.
  # This feature is quite annoying as it makes the print hard to read.
  # This sed adds new line after vmx-14/vmx-15/etc
  line=$(echo "$i" | sed 's/vmx-[0-9]*[ ]*/&\n/g' | tr -s ' ')

  # Split line into array, so the Annonation/notes can be indented
  readarray -t arr_split_line <<< "$line"

  if [[ "$line" != *"vmx-"* ]] && [[ "$line" != "Vmid Name"* ]]; then
    # Set nice indent before Annonation/Note lines
    echo "    $line"
  elif [[ "$line" == *"vmx-"* ]]; then
    echo "${arr_split_line[0]}"
  elif [[ "$line" == "Vmid Name"* ]]; then
    # Sed operations:
    # 1. Change "Guest OS" to "Guest_OS"
    # 2. Remove trailing spaces / tabs
    # 3. Replace spaces with ", "
    echo "${arr_split_line[0]}" | sed -e 's/Guest OS/Guest_OS/g' \
      -e 's/[ \t]*$//' \
      -e 's/ /, /g'
  fi
	
	# Check that the array item is not empty, and print with indent
  # https://unix.stackexchange.com/a/146945/375094
  if [[ ! -z "${arr_split_line[1]// }" ]]; then
    echo "    ${arr_split_line[1]}"
  fi
done
}


# By default some unnecessary information is printed by command
# "esxcli vm process list", so let's strip some information.
func_strip_esxcli_vm_process_list () {

file="$1"
readarray -t arr < "$file"

for i in "${arr[@]}"
do
  # Remove indent
  tmp_str=$(echo "$i" | sed 's/^[ \t]*//')

  # If line doesn't start with World, Process, VMX or UUID, print the line.
  # Those lines don't usually hold much value.
  if [[ "$tmp_str" != "World"* ]] && \
    [[ "$tmp_str" != "Process"* ]] && \
    [[ "$tmp_str" != "VMX"* ]] && \
    [[ "$tmp_str" != "UUID"* ]]; then

    echo "$i"

  fi
done
}


# For processing the output of "vsish -e get /memory/comprehensive"
func_process_mem_vsish () {

file="$1"

sed 's/:/ /' < "$file" | awk -v div=1024 -v div2=1048576 -v unit="MB" -v gbyte="GB" '
    /Phys/ { phys = $(NF-1); units = unit; width = length(phys) }
    /Free/ { free = $(NF-1) }
  END    { print width, units, phys / div, (phys-free) / div, free / div,
  phys / div2 , (phys-free) / div2, free / div2, gbyte }' |
  while read width units phys_mbyte used_mbyte free_mbyte \
    phys_gbyte used_gbyte free_gbyte gbyte ; do
      printf "Phys %.0f %s %s %.2f %s\n" $phys_mbyte $units "=" $phys_gbyte $gbyte
      printf "Used %.0f %s %s %.2f %s\n" $used_mbyte $units "=" $used_gbyte $gbyte
      printf "Free %.0f %s %s %.2f %s\n" $free_mbyte $units "=" $free_gbyte $gbyte
  done
}

func_create_style () {
html_file="$1"

style_section="<style>
  body {
    font-family: Consolas,Menlo,Monaco,Lucida Console,Liberation Mono,DejaVu
    Sans Mono,Bitstream Vera Sans Mono,Courier New,monospace,sans-serif;
    color: white;
    background-color: #2d2d2d;
  }
  .div-center-esxi {
    margin: auto;
    width: 70%;
    padding-bottom: 10px;
    padding-left: 10px;
    border: 3px solid brown;
    white-space: pre-wrap;
  }
  pre {
    margin: 0;
  }
  h1 {
    margin: 0px;
  }
  h2 {
    margin: 0px;
  }
  h3 {
    margin: 0px;
  }
  .div-title {
    background-color: black;
    color: orange;
    width: max-content;
    padding: 10px;
  }
  .div-h1-heading {
    background-color: black;
    color: orange;
    width: max-content;
    padding-left: 10px;
    padding-right: 10px;
  }
  .div-h3-heading {
    background-color: black;
    color: orange;
    width: max-content;
    padding-left: 10px;
    padding-right: 10px;
  }
  .div-esxi-data {
    color: white;
    background-color: black;
    padding-left: 10px;
    padding-bottom: 10px;
  }
  .div-esxi-version {
    maring: auto;
    width: max-content;
    color: white;
    background-color: black;
    padding-left: 10px;
    padding-right: 10px;
    padding-bottom: 10px;
  }
  .div-esxi-never-worked {
    color: black;
    background-color: #CC99CC;
  }
  .div-esxi-unreachable {
    color: black;
    background-color: #A28B30;
  }
</style>
"

# https://stackoverflow.com/a/32014701/3498768
awk -v style="$style_section" '
/<body>/ {
  print style
}
{ print }
' "$html_file" > tmp.html && mv tmp.html "$html_file"

}

func_esxi_data_to_html () {
  file_to_add="$1"
  echo '<div class="div-esxi-data">' >> "$index_html"
  if [ -f "$file_to_add" ]; then
    cat "$file_to_add" >> $index_html
  else
    echo "$file_to_add" >> $index_html
  fi
  echo '</div>' >> "$index_html"
}

func_h3_to_html () {
  h3_heading="$1"
  echo '<div class="div-h3-heading">' >> "$index_html"
  echo "$h3_heading" >> "$index_html"
  echo '</div>' >> "$index_html"
}

func_generate_html () {
esxi="$1"

# Check if ESXi output directory exists.
# This will tell us if the ESXi has been connected succesfully via SSH
# and data has been copied.
# If the directory doesn't exist, write instructions and don't go further in this function.
if [ ! -d "$esxi_info_path""$esxi" ]; then

tee -a "$index_html" > /dev/null << EOL
<hr>
<pre>
<div class="div-esxi-never-worked">
<center><h1>$esxi</h1></center>
<div class="div-center-esxi">
The SSH connection to ESXi did not work and probably has never worked.
Check that SSH is enabled on the ESXi https://kb.vmware.com/s/article/2004746
The last check: $(date)
</div>
</div>
</pre>
EOL

return

fi

# Retrieve what is the date on the ESXi in seconds and
# get the difference of script running date and the latest ESXi contact
date_esxi_secs=$(cat "$esxi_info_path""$esxi"/date_secs.txt) && \
date_diff_secs=$(expr "$date_script_secs" - "$date_esxi_secs")

# /dev/null, so that the HTML is not printed on shell.
tee -a $index_html > /dev/null << EOL
<hr>
<pre>
<center>
<div class="div-h1-heading">
<h1>$esxi</h1>
</center>
</div>
EOL

# When difference is over 300 seconds (5 minutes), give warning.
if [ "$date_diff_secs" -gt 300 ]; then
  tee -a "$index_html" > /dev/null << EOL
<div class="div-esxi-unreachable">
<center><h2>This ESXi is unreachable.</h2></center>
EOL
else
  echo "<div>" >> "$index_html"
fi

# ESXi version
echo '<center><div class="div-esxi-version">' >> "$index_html"
cat "$esxi_info_path/$esxi/esxi_version.txt" >> "$index_html"
echo '</div></center>' >> "$index_html"

# Print last check date. This can be different than what the last
# run date of the whole script is, because if the ESXi goes offline
# the files are not update and old information gets written to html file.
last_check=$(cat "$esxi_info_path""$esxi"/date.txt)
echo "<center>The last check: $last_check</center>" >> $index_html

# Management Network information
func_h3_to_html "<h3>esxcli network ip interface ipv4 get</h3>"
func_esxi_data_to_html "$esxi_info_path/$esxi/ip_addr.txt"

# Storage usage
func_h3_to_html "<h3>df -h</h3>"
func_esxi_data_to_html "$esxi_info_path/$esxi/storage_usage.txt"

# Memory usage
func_h3_to_html "<h3>Memory</h3>"
tmp_mem_vsish=$(func_process_mem_vsish "$esxi_info_path/$esxi/memory_vsish.txt")
func_esxi_data_to_html <<< cat "$tmp_mem_vsish"

# Print which VMs are running
func_h3_to_html "<h3>esxcli vm process list</h3>"
tmp_vms=$(func_strip_esxcli_vm_process_list "$esxi_info_path/$esxi/esxcli-vm-process-list.txt")
func_esxi_data_to_html <<< cat "$tmp_vms"

# Print registered VMs
func_h3_to_html "<h3>vim-cmd vmsvc/getallvms</h3>"
tmp_getallvms=$(func_print_getallvms "$esxi_info_path/$esxi/getallvms.txt")
func_esxi_data_to_html <<< cat "$tmp_getallvms"

# Print VMs that are in local-vms datastore
# There can be VMs that are not registered (backups/etc)
func_h3_to_html "<h3>ls -l /vmfs/volumes/&lt;storage_name&gt;</h3>"
tmp_storage=$(cat $esxi_info_path/$esxi/storage_ls_*.txt)
func_esxi_data_to_html <<< cat "$tmp_storage"

# Print filesystems
func_h3_to_html "<h3>esxcli storage filesystem list</h3>"
func_esxi_data_to_html $esxi_info_path/$esxi/filesystem_list.txt

echo "</pre>" >> $index_html
echo "</div>" >> $index_html
}

func_write_html_head () {
html_file="$1"
tee -a $html_file > /dev/null << EOL
<!DOCTYPE html
<html>
<head>
	<meta http-equiv="content-type" content="text/html; charset=utf-8" />
  <title>ESXis</title>
</head>

<body>
<center>
<h1>
<div class="div-title">
  ESXi information, what is running where
</div>
</h1>
</center>
<br>
<center>The script has been run last time on $(date)</center>
<br>
<center>Attention, the timezones of the script server and ESXi hosts can be differ.</center>
<center>Compare UTC/CEST/etc timezone on the timestamp if you are confused.</center>
EOL
}

func_write_html_end () {
html_file="$1"
tee -a $html_file > /dev/null << EOL
</body>
</html>
EOL
}

# THIS IS UNNECESSARY
func_load_esxis_from_file () {
# Give the ESXis in a file as a positional parameter
esxis_file="$1"

# Remove spaces or tabs from beginning of lines.
# Reading file using cat.
esxis_file=$(cat "$esxis_file" | sed 's/^[ \t]*//g')

# Remove lines starting with # hashtag (remove comments)
# Reading variable using echo.
esxis_file=$(echo "$esxis_file" | sed '/^#/d')

# Remove lines that don't start with "host:"
esxis_file=$(echo "$esxis_file" | sed '/^host:/!d')

# Remove "host:" from the beginning of lines
esxis_file=$(echo "$esxis_file" | sed 's/^host://g')

# Remove again space or tabs beginning of lines. 
esxis_file=$(echo "$esxis_file" | sed 's/^[ \t]*//g')

# Remove all trailing spaces or tabs
esxis_file=$(echo "$esxis_file" | sed 's/[ \t]*$//')

echo "Read ESXis read from file:"

# Process Substition example:
# https://stackoverflow.com/a/19571082
while IFS= read -r line
do
echo "    $line"
arr_esxis+=("$line")
done < <(echo "$esxis_file")

}

# Parsing configuration from config.conf
func_load_config () {

echo "Reading configuration from file:"

conf_file="$1"

# Remove spaces or tabs from beginning of lines.
# Reading file using cat.
conf_file=$(cat "$conf_file" | sed 's/^[ \t]*//g')

# Remove lines starting with # hashtag (remove comments)
# Reading variable using echo.
conf_file=$(echo "$conf_file" | sed '/^#/d')

# Remove all trailing spaces or tabs
esxis_file=$(echo "$esxis_file" | sed 's/[ \t]*$//')

# Process Substition example:
# https://stackoverflow.com/a/19571082
while IFS= read -r line
do
    # Debug
    #echo "    $line"
    # Parse "host:", -n checks if string is longer than zero.
    if [ -n "$(echo $line | grep '^host:')" ]
    then
        # Remove "host: (and any space/tabs)" from the beginning of line
        line=$(echo "$line" | sed 's/^host:[ \t]*//g')
        arr_esxis+=("$line")
    # Parse: "ssh_key:"
    elif [ -n "$(echo $line | grep '^ssh_key:')" ]
    then
        line=$(echo "$line" | sed 's/^ssh_key:[ \t]*//g')
        if [ -n "$line" ]
        then
            ssh_key="$line"
        else
            echo "    INFO: No ssh_key given."
        fi
    elif [ -n "$(echo $line | grep '^www_directory:')" ]
    then
        line=$(echo "$line" | sed 's/^www_directory:[ \t]*//g')
        if [ -n "$line" ]
        then
            www_dir="$line"
        else
            echo "    INFO: No www_directory given. Using default: $www_dir"
        fi
    elif [ -n "$(echo $line | grep '^esxi_output_path:')" ]
    then
        line=$(echo "$line" | sed 's/^esxi_output_path:[ \t]*//g')
        if [ -n "$line" ]
        then
            esxi_info_path="$line"
        else
            echo "    INFO: No esxi_output_path given. Using default: $esxi_info_path"
        fi
    elif [ -n "$(echo $line | grep '^require_sudo:')" ]
    then
        line=$(echo "$line" | sed 's/^require_sudo:[ \t]*//g')
        if [ -n "$line" ]
        then
            require_sudo="$line"
        else
            echo "    INFO: require_sudo was not defined. Using default: yes"
        fi
    fi

done < <(echo "$conf_file")

echo "Parsed configuration:"
echo "    ESXis: ${arr_esxis[*]}"
echo "    SSH key: $ssh_key"
echo "    WWW dir: $www_dir"
echo "    ESXi output path: $esxi_info_path"
echo "    Require sudo: $require_sudo"
}


func_loop_esxis () {
printf "Retrieving and generating information of ESXis via SSH:\n"

# Retrieve information from ESXis that can be connected via SSH 
for esxi in "${arr_esxis_ssh[@]}"; do
    echo ""
    echo "######################################" 
    printf "######\t$esxi\n"
    echo "######################################"
    echo ""
    # Generate information on ESXi
    echo "Generating ESXi information via SSH"
    func_run_esxi_script "$esxi"

    # Copy information files from ESXi to local disk
    echo "Copying ESXi information to local disk"
    mkdir -p "$esxi_info_path""$esxi"
    scp -i "$ssh_key" root@"$esxi":/tmp/random-stuff/* "$esxi_info_path""$esxi"
done

# Add ESXi information of every host to HTML page
# It doesn't matter if hosts have never been able to contact via SSH as
# then the informations will be just empty. And if some hosts have been
# previously connected, but have been removed/can't be connected,
# latest locally stored information will be written to the HTML page. 
echo "Appending ESXi information to HTML page"
for esxi in "${arr_esxis[@]}"; do
    # Add ESXi information to HTML page 
    echo "    $esxi"
    func_generate_html "$esxi"
done
}


# Function for testing that SSH can be connected to host
func_test_esxi_connections () {
echo "Checking that ESXis can be connected via SSH"

# Temp array for storing values when removing from original.
# Source: https://stackoverflow.com/a/31122840
for esxi in "${arr_esxis[@]}"; do
  echo "    $esxi"
  ssh_error=$(ssh -i "$ssh_key" root@"$esxi" "exit" 2>&1 > /dev/null)
  # If error variable is empty, add ESXi to temp array
  if [ -z "$ssh_error" ]
  then
    arr_esxis_ssh+=($esxi)
  else
    echo "    ERROR: $ssh_error"
  fi
done

# Check if any ESXis that can be connected via SSH
if (( ! ${#arr_esxis_ssh[@]} ))
then
  echo "Error: None of the ESXis configured in $config_file could be connected!"
else
  echo "ESXis that can be connected via SSH:"
  printf '    %s\n' "${arr_esxis_ssh[@]}"
fi
}

# Function creates esxi-archive directory.
# Symbolic link is created to point the newest HTML file.
func_rotate_archive () {

# Create servers-archive
mkdir -p "$www_dir"/esxi-archive
# Create new index.html, remove old symlink and create new symlink to the new index.html
index_html="$www_dir"/esxi-archive/index-${datefile}.html
if [ -f "$www_dir"/index.html ]; then
  rm "$www_dir"/index.html
fi

ln -s "$index_html" "$www_dir"/index.html
}

func_require_sudo () {
# Checking that the script has been executed as a superuser
if [ "$require_sudo" != "no" ] && [ "$USER" != "root" ]; then
  tput setaf 3; # Yellow text
  echo "This script should be executed as superuser - use sudo!" 2>&1
  echo "Exiting..." 2>&1
  tput sgr0; # Default text color
  exit 1
fi
}

###### DEFAULT VARIABLES ######

# SSH key for accessing ESXis
ssh_key=""

# Array for looping ESXi information
# Add ESXi DNS names or IPs to the array.
arr_esxis=()

# This array is for checking which ESXis can be connected via SSH.
arr_esxis_ssh=()

# Variable for adding date into file names
datefile=$(date +"%Y-%m-%d_%H-%M")

# For checking if ESXi info is fresh
date_script_secs=$(date +%s)

# Script path
script_path=$(func_get_script_source_dir)

# Create path variable for storing ESXi information
esxi_info_path=$script_path/esxi_infos/

# Apache/httpd/nginx www directory
www_dir="$script_path/www/"

# Configuration file
config_file="$script_path/config.conf"

# Require sudo
require_sudo="no"


###### SCRIPT MAIN ######

# Read ESXis from file
func_load_config "$config_file"

# Check if the script should be run with sudo
func_require_sudo

# Creating directories, using either config.conf or defaults above
mkdir -p $esxi_info_path
mkdir -p $www_dir

func_rotate_archive

# Start writing to HTML file
func_write_html_head "$index_html"

#func_load_esxis_from_file "$config_file"
func_test_esxi_connections

# Loop through ESXis that were loaded to arr_esxis
func_loop_esxis

# Add style section to the HTML file, the overwriting is intentional as the
# function prints the whole new file.
#func_create_style "$index_html" >> "$index_html"

func_create_style "$index_html"

# Append HTML end tags to the end of HTML file
func_write_html_end "$index_html"

# symlink doesn't work with WSL when opening with browser from File Explorer,
# so let's check: if using WSL, remove symlink and copy the index.html from
# archive.
# 1st check WSL1 output: 4.4.0-19041-Microsoft
# 2nd check WSL2 output: 5.4.72-microsoft-standard-WSL2
if [[ $(uname -r) =~ Microsoft$ || $(uname -r) =~ WSL2$ ]]; then
  echo "Using WSL (Windows Subsystem for Linux): $(uname -r)"
  rm "$www_dir"/index.html
  cp "$index_html" "$www_dir"/index.html
fi

exit 0
