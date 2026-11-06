# -*- mode: ruby -*-
# vi: set ft=ruby :

Vagrant.configure("2") do |config|
  # Debian's own debian/trixie64 box is published for libvirt only.
  # bento/debian-13 is a Debian 13 base box with a VirtualBox image,
  # which is the provider CONTRIBUTING.md tells developers to install.
  config.vm.box = "bento/debian-13"

  config.vm.provider "virtualbox" do |vb|
    # Nextcloud, SpamAssassin and the build of the management venv need
    # more than VirtualBox's 512 MB default.
    vb.memory = 2048
  end

  # Network config: Since it's a mail server, the machine must be connected
  # to the public web. However, we currently don't want to expose SSH since
  # the machine's box will let anyone log into it. So instead we'll put the
  # machine on a private network.
  config.vm.hostname = "mailinabox.lan"
  config.vm.network "private_network", ip: "192.168.56.4"

  config.vm.provision :shell, :inline => <<-SH
    # Set environment variables so that the setup script does
    # not ask any questions during provisioning. We'll let the
    # machine figure out its own public IP.
    export NONINTERACTIVE=1
    export PUBLIC_IP=auto
    export PUBLIC_IPV6=auto
    export PRIMARY_HOSTNAME=auto
    #export SKIP_NETWORK_CHECKS=1

    # Start the setup script.
    cd /vagrant
    setup/start.sh
SH
end
