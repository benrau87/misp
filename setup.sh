#!/bin/bash

if [ "$EUID" -ne 0 ]
  then echo "Please run as root"
  exit 1
fi

RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'
gitdir=$PWD

echo -e "${YELLOW}Updating system...Please wait.${NC}"
apt-get -qq update && sudo apt-get upgrade -y && sudo apt-get upgrade -y && sudo apt-get dist-upgrade -y && sudo apt-get autoremove -y

echo -e "${YELLOW}Installing dependencies...Please wait.${NC}"

apt-get -qq install postfix curl gcc git gnupg-agent make python openssl redis-server sudo vim zip mariadb-client mariadb-server apache2 apache2-doc apache2-utils libapache2-mod-php php php-cli php-crypt-gpg php-dev php-json php-mysql php-opcache php-readline php-redis python-dev python-pip libxml2-dev libxslt1-dev zlib1g-dev python-setuptools -y

# Secure the MariaDB installation (especially by setting a strong root password)
mysql_secure_installation

# Enable modules, settings, and default of SSL in Apache
a2dismod status
a2enmod ssl
a2enmod rewrite
a2dissite 000-default
a2ensite default-ssl
systemctl restart apache2

# Download MISP using git in the /var/www/ directory.
sudo mkdir /var/www/MISP
sudo chown www-data:www-data /var/www/MISP
cd /var/www/MISP
sudo -u www-data git clone https://github.com/MISP/MISP.git /var/www/MISP
sudo -u www-data git checkout tags/$(git describe --tags `git rev-list --tags --max-count=1`)


# Make git ignore filesystem permission differences
sudo -u www-data git config core.filemode false

cd /var/www/MISP/app/files/scripts
sudo -u www-data git clone https://github.com/CybOXProject/python-cybox.git
sudo -u www-data git clone https://github.com/STIXProject/python-stix.git
cd /var/www/MISP/app/files/scripts/python-cybox
sudo -u www-data git checkout v2.1.0.12
sudo python setup.py install
cd /var/www/MISP/app/files/scripts/python-stix
sudo -u www-data git checkout v1.1.1.4
sudo python setup.py install

# CakePHP is included as a submodule of MISP, execute the following commands to let git fetch it:
cd /var/www/MISP
sudo -u www-data git submodule init
sudo -u www-data git submodule update

# Once done, install CakeResque along with its dependencies if you intend to use the built in background jobs:
cd /var/www/MISP/app
sudo -u www-data wget https://getcomposer.org/download/1.2.1/composer.phar -O composer.phar
sudo -u www-data php composer.phar require kamisama/cake-resque:4.1.2
sudo -u www-data php composer.phar config vendor-dir Vendor
sudo -u www-data php composer.phar install

# Enable CakeResque with php-redis
sudo phpenmod redis

# To use the scheduler worker for scheduled tasks, do the following:
sudo -u www-data cp -fa /var/www/MISP/INSTALL/setup/config.php /var/www/MISP/app/Plugin/CakeResque/Config/config.php

# Check if the permissions are set correctly using the following commands:
sudo chown -R www-data:www-data /var/www/MISP
sudo chmod -R 750 /var/www/MISP
sudo chmod -R g+ws /var/www/MISP/app/tmp
sudo chmod -R g+ws /var/www/MISP/app/files
sudo chmod -R g+ws /var/www/MISP/app/files/scripts/tmp

# Apache Configurations
sudo cp /var/www/MISP/INSTALL/apache.misp.ssl /etc/apache2/sites-available/misp-ssl.conf
sudo openssl req -newkey rsa:4096 -days 365 -nodes -x509 -keyout /etc/ssl/private/misp.local.key -out /etc/ssl/private/misp.local.crt

echo
echo -e "${YELLOW}What is the IP address of the machine that is hosting the cuckoo webpage?${NC}"
read ipaddr
echo

sudo tee -a /tmp/misp-ssl.conf <<EOF

<VirtualHost $ipaddr:80>
        ServerName $ipaddr

        Redirect permanent / https://$ipaddr

        LogLevel warn
        ErrorLog /var/log/apache2/misp.local_error.log
        CustomLog /var/log/apache2/misp.local_access.log combined
        ServerSignature Off
</VirtualHost>

<VirtualHost ipaddr:443>
        ServerAdmin admin@misp.local
        ServerName $ipaddr
        DocumentRoot /var/www/MISP/app/webroot
        <Directory /var/www/MISP/app/webroot>
                Options -Indexes
                AllowOverride all
                Order allow,deny
                allow from all
        </Directory>

        SSLEngine On
        SSLCertificateFile /etc/ssl/private/misp.local.crt
        SSLCertificateKeyFile /etc/ssl/private/misp.local.key
#        SSLCertificateChainFile /etc/ssl/private/misp-chain.crt

        LogLevel warn
        ErrorLog /var/log/apache2/misp.local_error.log
        CustomLog /var/log/apache2/misp.local_access.log combined
        ServerSignature Off
</VirtualHost>
EOF

cp /tmp/misp-ssl.conf /etc/apache2/sites-available/
sudo a2dissite default-ssl
sudo a2ensite misp-ssl
sudo systemctl restart apache2

# There are 4 sample configuration files in /var/www/MISP/app/Config that need to be copied
sudo -u www-data cp -a /var/www/MISP/app/Config/bootstrap.default.php /var/www/MISP/app/Config/bootstrap.php
sudo -u www-data cp -a /var/www/MISP/app/Config/database.default.php /var/www/MISP/app/Config/database.php
sudo -u www-data cp -a /var/www/MISP/app/Config/core.default.php /var/www/MISP/app/Config/core.php
sudo -u www-data cp -a /var/www/MISP/app/Config/config.default.php /var/www/MISP/app/Config/config.php


# Configure the fields in the newly created files:
sudo -u www-data vim /var/www/MISP/app/Config/database.php

# Change base url in config.php
sudo -u www-data vim /var/www/MISP/app/Config/config.php

# and make sure the file permissions are still OK
sudo chown -R www-data:www-data /var/www/MISP/app/Config
sudo chmod -R 750 /var/www/MISP/app/Config

# Generate a GPG encryption key.
#sudo -u www-data mkdir /var/www/MISP/.gnupg
#sudo chmod 700 /var/www/MISP/.gnupg
#sudo -u www-data gpg --homedir /var/www/MISP/.gnupg --gen-key

# And export the public key to the webroot
#sudo -u www-data sh -c "gpg --homedir /var/www/MISP/.gnupg --export --armor YOUR-KEYS-EMAIL-HERE > /var/www/MISP/app/webroot/gpg.asc"

# To make the background workers start on boot
sudo chmod +x /var/www/MISP/app/Console/worker/start.sh
echo "sudo -u www-data bash /var/www/MISP/app/Console/worker/start.sh" | tee -a /etc/rc.local

# MISP has a new pub/sub feature, using ZeroMQ. To enable it, simply run the following command
sudo pip install pyzmq
# ZeroMQ depends on the Python client for Redis
sudo pip install redis
