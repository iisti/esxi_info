#!/usr/bin/env bash

# Array for looping ESXi information
# Add ESXi DNS names or IPs to the array.
arr_esxis=()

ssh_pub_key=""

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
    # Parse: "ssh_pub_key:"
    elif [ -n "$(echo $line | grep '^ssh_pub_key:')" ]
    then
        line=$(echo "$line" | sed 's/^ssh_pub_key:[ \t]*//g')
        if [ -n "$line" ]
        then
            ssh_pub_key="$line"
        else
            echo "    INFO: No ssh_pub_key given."
        fi
    fi

done < <(echo "$conf_file")

echo "Parsed configuration:"
echo "    ESXis: ${arr_esxis[*]}"
echo "    SSH public key path: $ssh_pub_key"
echo "    SSH public key content:"; cat "$ssh_pub_key"

}

func_add_ssh_pub_key () {
echo "Adding public SSH key to ESXis:"
for esxi in "${arr_esxis[@]}"; do
	echo "    $esxi"
	cat "$ssh_pub_key" | ssh root@"$esxi" -T "cat >> /etc/ssh/keys-root/authorized_keys"
done
}

func_load_config ./config.conf
func_add_ssh_pub_key
