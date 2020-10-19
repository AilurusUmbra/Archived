#!/bin/bash

echo "$(whoami)"

[ "$UID" -eq 0 ] || sudo "$0" "$@"

case $(uname -s) in
    Linux) os="linux" ;;
    *) os="not_linux" ;;
esac

if [ "$os" = "not_linux" ]; then
    echo "Unsupported OS $(uname -s). Only Linux binaries are available."
	exit
fi

case $(uname -m) in
x86_64) arch="x86_64" ;;
*) arch="other" ;;
esac

if [ "$arch" = "other" ]; then
	echo "Unsupported architecture $(uname -m). Only x64 binaries are available."
	exit
fi

test_program_installed () {
    if command -v $1 > /dev/null; then
        echo "Program $1 successfully installed"
    else
        echo "Program $1 not installed"
        exit 1
    fi
}

install_docker() {
    # Uninstall old versions
    apt-get remove -qq docker docker-engine docker.io containerd runc
    # Update
    apt-get update -qq
    # Install packages to allow apt to use a repository over HTTPS
    apt-get -qq install \
    apt-transport-https \
    ca-certificates \
    curl \
    gnupg-agent \
    software-properties-common
    # Add Docker’s official GPG key
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | apt-key add -
    # Add repository
    add-apt-repository -y \
    "deb [arch=amd64] https://download.docker.com/linux/ubuntu \
    $(lsb_release -cs) \
    stable"
    # Update
    apt-get -qq update
    apt-get -qq install docker-ce docker-ce-cli containerd.io
}

check_docker_version() {
    req_ver='19.03.0'
    installed_ver=$(docker --version | cut -f3 -d ' ' | sed 's/,//g')

    if [[ "$req_ver" < "$installed_ver" || "$req_ver" == $installed_ver ]]; then
        echo "Docker version ${installed_ver} is suitable - minimal required version ${req_ver}."
    else
        echo "Docker version ${installed_ver} is not suitable - minimal required version ${req_ver}."
        exit 1
    fi
}

install_nvidia_docker() {
    # Install nvidia-docker2 for nomad
    sudo apt-get install nvidia-docker2

    # Add the package repositories
    distribution=$(. /etc/os-release;echo $ID$VERSION_ID)
    curl -s -L https://nvidia.github.io/nvidia-docker/gpgkey | sudo apt-key add -
    curl -s -L https://nvidia.github.io/nvidia-docker/$distribution/nvidia-docker.list | sudo tee /etc/apt/sources.list.d/nvidia-docker.list

    sudo apt-get update && sudo apt-get install -y nvidia-container-toolkit
    sudo systemctl restart docker
}

install_nvidia_drivers() {
    if lspci | grep -i nvidia > /dev/null; then
        echo "NVIDIA grafic card available"
    else
        echo "NVIDIA grafic card is missing"
        exit 1
    fi

    distro='ubuntu'
    arch='x86_64'
    version='1804'

    case $(uname -m && cat /etc/*release) in
    *Ubuntu*18.10*|*Ubuntu*18.04*) version='1804';;
    *Ubuntu*16.04*) version='1604';;
    *Ubuntu*14.04*) version='1404';;
    *) echo "Unsupported version of OS"; exit 1;;
    esac

    if command -v gcc --version > /dev/null; then
        echo "Program gcc --version successfully installed"
    else
        echo "Program gcc --version not installed. Installing"
        sudo apt -qq -y install gcc
    fi
    
    sudo apt-get -qq -y install linux-headers-$(uname -r)

    sudo wget "https://developer.download.nvidia.com/compute/cuda/repos/$distro$version/$arch/cuda-$distro$version.pin"
    sudo mv "cuda-$distro$version.pin" /etc/apt/preferences.d/cuda-repository-pin-600
    sudo apt-key adv -qq --fetch-keys "https://developer.download.nvidia.com/compute/cuda/repos/$distro$version/$arch/7fa2af80.pub"
    sudo add-apt-repository "deb http://developer.download.nvidia.com/compute/cuda/repos/$distro$version/$arch/ /"
    sudo apt-get update -qq
    sudo apt-get -y -qq install cuda-drivers
    sudo systemctl restart docker
}

make_config () {
  token="$1"
  ports="$2"

  file="$fluidstack_home/.fs_config.yaml"

  echo "################################################################################" > $file
  echo "# FluidStack node config file in yaml format                                   #" >> $file
  echo "################################################################################" >> $file
  echo "" >> $file
  echo "################################################################################" >> $file
  echo "# clusterToken                                                                 #" >> $file
  echo "# A token unique to a provider that can be found on the provider dashboard     #" >> $file
  echo "# https://provider.fluidstack.io/dashboard                                     #" >> $file
  echo "################################################################################" >> $file
  echo "# clusterToken: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" >> $file

  echo "" >> $file
  echo "clusterToken: ${token}" >> $file
  echo "" >> $file

  echo "################################################################################" >> $file
  echo "# ports                                                                        #" >> $file
  echo "# A list of port forwards from the router to an internal port in format        #" >> $file
  echo "# 'local: external'  Can be left empty if UPnP is enabled on the router.       #" >> $file
  echo "################################################################################" >> $file
  echo "# ports:" >> $file
  echo "#   1000: 2000" >> $file
  echo "#   1001: 2001" >> $file

  echo "" >> $file
  echo -n "ports:" >> $file

  IFS=',' read -ra MAPPINGS <<< "$ports"
  for mapping in "${MAPPINGS[@]}"; do
    p1=""
    p2=""

    IFS=':' read -ra PORTS <<< "$mapping"
    for port in "${PORTS[@]}"; do
      if [[ "$p1" -eq "" ]]; then
        p1="$port"
      else
        p2="$port"
      fi
    done

    printf "\n  %s: %s" "$p1" "$p2" >> "$file"
  done

  echo "" >> $file
}

prompt_cluster_token() {
  loop="true"

  while $loop -eq "true"; do
    read -p "Enter your cluster token: " -r </dev/tty

    IFS='-' read -ra TOKEN_PARTS <<< "$REPLY" # split string by dash
    c=0 # parts in string, expect 4

    for _ in "${TOKEN_PARTS[@]}"; do
      c=$((c + 1))
    done

    if [[ $c != "5" ]]; then
      echo "Bad token, please try again (e.g. '12358f2d9-5d6g-4b3b-a7c3-cc1233dcb123')"
    else
      loop="false"
    fi
  done

  cluster_token="$REPLY"
}

prompt_ports() {
  loop="true"
    
  while $loop -eq "true"; do
    read -p "Enter port mappings as local:external, separated by a comma eg: (3000:4000). You can leave empty if UPnP is allowed on router: " -r </dev/tty

    IFS=',' read -ra PORT_MAPPINGS <<< "$REPLY" # split string by comma
    c=0 # parts in string
    bad_mapping="false"

    [[ $REPLY == '' ]] && return

    for i in "${PORT_MAPPINGS[@]}"; do
      c=$((c + 1))

      # check port mapping contains colon
      if [[ ${i} != *":"* ]]; then
        bad_mapping="$PORT_PARTS"
      fi

      # check it has two ports either side of colon
      IFS=':' read -ra PORT_PARTS <<< "$i" # split string by colon
      pc=0 # parts in port mapping, expect 2

      for p in "${PORT_PARTS[@]}"; do
        pc=$((pc + 1))
      done

      if [[ $pc -ne "2" ]]; then
        bad_mapping="$PORT_PARTS"
        break
      else
        bad_mapping="false"
      fi
    done

    if [[ "$bad_mapping" -ne "false" ]]; then
      echo "Bad port mapping: \"$bad_mapping\""
    elif [[ $c -lt "5" ]]; then
      echo "Expecting at least 5 ports mapping (e.g. \"4000:5000\")"
    else
      loop="false"
    fi
  done

  ports="$REPLY"
}

fluidstack_home="/usr/local/fluidstack"
fluidstack_lib="$fluidstack_home/lib"
fluidstack_bin="$fluidstack_home/bin"
fluidstack_nomad_dir="$fluidstack_home/nomad"

if [ ! -d "$fluidstack_home" ]; then
    echo "Creating new home directory"
    mkdir -p $fluidstack_home/{lib,bin,tmp}
fi

fluidstack_user="root"
fluidstack_group="root"

# Install Docker
install_docker
check_docker_version
# Install nvidia cuda drivers
install_nvidia_drivers
# Install nvidia docker support
install_nvidia_docker

# Set variables
node_version="v0.7.5"
archive_folder="$fluidstack_lib/$node_version"
archive_name=$node_version"_linux.tar.gz"
archive="$fluidstack_lib/$archive_name"
exec="fluidnode"
unit_file="fluidstack.service"
release_bucket="fluidstack-releases"
release_uri="https://$release_bucket.s3.eu-west-2.amazonaws.com/$archive_name"

curl -fL# -o "$archive" "$release_uri"
[ -d "$archive_folder" ] || mkdir $archive_folder
tar -C $archive_folder -zxf $archive && rm $archive

rm "$fluidstack_bin/$exec"
ln -s "$archive_folder/$exec" "$fluidstack_bin/$exec"

# Change owner of whole dir
chown $fluidstack_user:$fluidstack_group "$fluidstack_bin/$exec"

test_program_installed "$fluidstack_bin/$exec"

cp "$archive_folder/$unit_file" "/lib/systemd/system/$unit_file"
chmod 755 "/lib/systemd/system/$unit_file"

# Install and test ffmpeg binaries
cp "$archive_folder/ffmpeg" /usr/local/bin
chown $fluidstack_user:$fluidstack_group /usr/local/bin/ffmpeg
chmod +x /usr/local/bin/ffmpeg
test_program_installed "ffmpeg"

# Setup syslog
echo "if \$programname == 'fluidstack' then /path/to/log/file.log& stop" > /etc/rsyslog.d/30-fluidstack.conf

echo chmod +x "$archive_folder/$exec"
chmod +x "$archive_folder/$exec"
chown -R $fluidstack_user:$fluidstack_group "$fluidstack_home"

prompt_cluster_token # sets ret value on $cluster_token
prompt_ports # sets ret value on $ports
make_config "$cluster_token" "$ports"

# Install and test nomad binary
cp "$archive_folder/nomad" $fluidstack_bin
chown $fluidstack_user:$fluidstack_group "$fluidstack_bin/nomad"
chmod +x "$fluidstack_bin/nomad"
test_program_installed "$fluidstack_bin/nomad"

# Setup nomad dirs
mkdir -p "$fluidstack_nomad_dir/certs"
mkdir -p "$fluidstack_nomad_dir/conf"
mkdir -p "$fluidstack_nomad_dir/data"

# Move Nomad config
cp "$archive_folder/client.hcl" "$fluidstack_nomad_dir/conf"

systemctl daemon-reload
systemctl restart rsyslog

systemctl enable fluidstack.service
systemctl start fluidstack

if [ $? -ne 0 ]; then
  echo "Installation has failed"
  exit 1
fi

echo "Installation complete"
