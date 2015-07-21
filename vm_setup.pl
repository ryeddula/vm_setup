#!/usr/bin/perl
# vm_setup
# Utility script to help setup VMs on cPanel VMs.

# Code must be perl v5.8.8 complaint
# to ensure that it can be run on all supported distros.
#
# Do NOT use non-core modules.

use strict;
use warnings;

use Getopt::Long;
use Fcntl;
$| = 1;

my $VERSION = '0.3.2';

# get opts
my $opts = {
    'run_upcp'                 => 0,
    'run_check_cpanel_rpms'    => 0,
    'install_task_cpanel_core' => 0,
    'force'                    => 0,
    'install_cloudlinux'       => 0,

    # Optional configuration options' defaults:
    'sub' => {
        'hostname'      => 'daily.cpanel.vm',
        'metadata_host' => $ENV{'EC2_METADATA_HOST'},
    },
};

GetOptions(
    'help'             => \&usage,
    'full'             => \&enable_everything,
    'force'            => \$opts->{'force'},
    'installcl'        => \$opts->{'install_cloudlinux'},
    'upcp!'            => \$opts->{'run_upcp'},
    'check_rpms!'      => \$opts->{'run_check_cpanel_rpms'},
    'install_taskcore' => \$opts->{'install_task_cpanel_core'},

    # Optional configuration options:
    'hostname=s'      => \$opts->{'sub'}->{'hostname'},
    'metadata_host=s' => \$opts->{'sub'}->{'metadata_host'},
);

# Globals
my ( $ip, $natip );

# print header
print "\n[*] VM Server Setup Script\n";
print "[*] Version: $VERSION\n\n";

# generate random password
my $rndpass = random_pass();

### and go
if ( -e "/root/vmsetup.lock" ) {
    if ( !$opts->{'force'} ) {
        print "/root/vmsetup.lock exists. This script may have already been run. Use --force to bypass. Exiting...\n";
        exit;
    }
    else {
        print "/root/vmsetup.lock exists. --force passed. Ignoring...\n";
    }
}

# create lock file
print "creating lock file\n";
system_formatted("touch /root/vmsetup.lock");

# check for and install prereqs
print "installing utilities via yum [mtr nmap telnet nc jq s3cmd bind-utils jwhois dev git]\n";
system_formatted("yum install mtr nmap telnet nc jq s3cmd bind-utils jwhois dev git -y");

# set hostname
print "setting hostname\n";
system_formatted("hostname $opts->{'sub'}->{'hostname'}");
sysopen( my $etc_hostname, '/etc/hostname', O_WRONLY | O_CREAT )
  or die print_formatted("$!");
print $etc_hostname "$opts->{'sub'}->{'hostname'}";
close($etc_hostname);

# set /etc/sysconfig/network
print "updating /etc/sysconfig/network\n";
unlink '/etc/sysconfig/network';
sysopen( my $etc_network, '/etc/sysconfig/network', O_WRONLY | O_CREAT )
  or die print_formatted("$!");
print $etc_network "NETWORKING=yes\n" . "NOZEROCONF=yes\n" . "HOSTNAME=" . $opts->{'sub'}->{'hostname'} . "\n";
close($etc_network);

# add resolvers - WE SHOULD NOT BE USING GOOGLE DNS!!! (or any public resolvers)
print "adding resolvers\n";
unlink '/etc/resolv.conf';
sysopen( my $etc_resolv_conf, '/etc/resolv.conf', O_WRONLY | O_CREAT )
  or die print_formatted("$!");
print $etc_resolv_conf "search cpanel.net\n" . "nameserver 208.74.121.103\n";
close($etc_resolv_conf);

# run /scripts/build_cpnat
print "running build_cpnat\n";
system_formatted("/scripts/build_cpnat");
chomp( $ip    = qx(cat /var/cpanel/cpnat | awk '{print\$2}') );
chomp( $natip = qx(cat /var/cpanel/cpnat | awk '{print\$1}') );

# create .whostmgrft to skip initial setup wizard
print "creating /etc/.whostmgrft\n";
sysopen( my $etc_whostmgrft, '/etc/.whostmgrft', O_WRONLY | O_CREAT )
  or die print_formatted("$!");
close($etc_whostmgrft);

# correct wwwacct.conf
print "correcting /etc/wwwacct.conf\n";
unlink '/etc/wwwacct.conf';
my $OSVER  = `cat /etc/redhat-release`;
my $MINUID = 500;
if ( $OSVER =~ 7.1 ) {
    $MINUID = 1000;
}
sysopen( my $etc_wwwacct_conf, '/etc/wwwacct.conf', O_WRONLY | O_CREAT )
  or die print_formatted("$!");
print $etc_wwwacct_conf "HOST $opts->{'sub'}->{'hostname'}\n"
  . "ADDR $natip\n"
  . "HOMEDIR /home\n"
  . "ETHDEV eth0\n"
  . "NS ns1.os.cpanel.vm\n"
  . "NS2 ns2.os.cpanel.vm\n" . "NS3\n" . "NS4\n"
  . "MINUID $MINUID\n"
  . "HOMEMATCH home\n"
  . "NSTTL 86400\n"
  . "TTL 14400\n"
  . "DEFMOD paper_lantern\n"
  . "SCRIPTALIAS y\n"
  . "CONTACTPAGER\n"
  . "MINUID\n"
  . "CONTACTEMAIL\n"
  . "LOGSTYLE combined\n"
  . "DEFWEBMAILTHEME paper_lantern\n";
close($etc_wwwacct_conf);

# correct /etc/hosts
print "correcting /etc/hosts\n";
unlink '/etc/hosts';
sysopen( my $etc_hosts, '/etc/hosts', O_WRONLY | O_CREAT )
  or die print_formatted("$!");
print $etc_hosts "127.0.0.1		localhost localhost.localdomain localhost4 localhost4.localdomain4\n" . "::1		localhost localhost.localdomain localhost6 localhost6.localdomain6\n" . "$ip		$opts->{'sub'}->{'hostname'}\n";
close($etc_hosts);

# fix screen perms
print "fixing screen perms\n";
system_formatted('rpm --setperms screen');

# make accesshash
print "making access hash\n";
$ENV{'REMOTE_USER'} = 'root';
system_formatted('/usr/local/cpanel/bin/realmkaccesshash');

# create test account
print "creating test account - cptest\n";
system_formatted( 'yes |/scripts/wwwacct cptest.tld cptest ' . $rndpass . ' 1000 paper_lantern n y 10 10 10 10 10 10 10 n' );
print "creating test email - testing\@cptest.tld\n";
system_formatted( '/scripts/addpop testing@cptest.tld ' . $rndpass );
print "creating test database - cptest_testdb\n";
system_formatted("mysql -e 'create database cptest_testdb'");
print "creating test db user - cptest_testuser\n";
system_formatted("mysql -e 'create user \"cptest_testuser\" identified by \" $rndpass \"'");
print "adding all privs for cptest_testuser to cptest_testdb\n";
system_formatted("mysql -e 'grant all on cptest_testdb.* TO cptest_testuser'");
system_formatted("mysql -e 'FLUSH PRIVILEGES'");
print "mapping cptest_testuser and cptest_testdb to cptest account\n";
system_formatted("/usr/local/cpanel/bin/dbmaptool cptest --type mysql --dbusers 'cptest_testuser' --dbs 'cptest_testdb'");

print "Updating tweak settings (cpanel.config)...\n";
system_formatted("/usr/bin/replace allowremotedomains=0 allowremotedomains=1 allowunregistereddomains=0 allowunregistereddomains=1 -- /var/cpanel/cpanel.config");

# upcp
if ( $opts->{'run_upcp'} ) {
    print "\nrunning upcp \n ";
    system_formatted('/scripts/upcp');
}

if ( $opts->{'run_check_cpanel_rpms'} ) {
    print "\nrunning check_cpanel_rpms \n ";
    system_formatted('/scripts/check_cpanel_rpms --fix');
}

if ( $opts->{'install_task_cpanel_core'} ) {
    print "\ninstalling Task::Cpanel::Core\n ";
    system_formatted('/scripts/perlinstaller Task::Cpanel::Core');
}

print "Installing root's crontab if missing...\n";
if ( !-s "/var/spool/cron/root" ) {
    sysopen( my $roots_cron, '/var/spool/cron/root', O_WRONLY | O_CREAT )
      or die print_formatted("$!");
    print $roots_cron "8,23,38,53 * * * * /usr/local/cpanel/whostmgr/bin/dnsqueue > /dev/null 2>&1
30 */4 * * * /usr/bin/test -x /usr/local/cpanel/scripts/update_db_cache && /usr/local/cpanel/scripts/update_db_cache
*/5 * * * * /usr/local/cpanel/bin/dcpumon >/dev/null 2>&1
56 0 * * * /usr/local/cpanel/whostmgr/docroot/cgi/cpaddons_report.pl --notify
7 0 * * * /usr/local/cpanel/scripts/upcp --cron
0 1 * * * /usr/local/cpanel/scripts/cpbackup
35 * * * * /usr/bin/test -x /usr/local/cpanel/bin/tail-check && /usr/local/cpanel/bin/tail-check
30 */2 * * * /usr/local/cpanel/bin/mysqluserstore >/dev/null 2>&1
15 */2 * * * /usr/local/cpanel/bin/dbindex >/dev/null 2>&1
45 */4 * * * /usr/bin/test -x /usr/local/cpanel/scripts/update_mailman_cache && /usr/local/cpanel/scripts/update_mailman_cache
15 */6 * * * /usr/local/cpanel/scripts/recoverymgmt >/dev/null 2>&1
15 */6 * * * /usr/local/cpanel/scripts/autorepair recoverymgmt >/dev/null 2>&1
30 5 * * * /usr/local/cpanel/scripts/optimize_eximstats > /dev/null 2>&1
0 2 * * * /usr/local/cpanel/bin/backup
2,58 * * * * /usr/local/bandmin/bandmin
0 0 * * * /usr/local/bandmin/ipaddrmap\n";
    close($roots_cron);
}

print "updating /etc/motd\n";
unlink '/etc/motd';
sysopen( my $etc_motd, '/etc/motd', O_WRONLY | O_CREAT )
  or die print_formatted("$!");
print $etc_motd "\nVM Setup Script created the following test accounts:\n" . "https://$ip:2087/login/?user=root&pass=cpanel1\n" . "https://$ip:2083/login/?user=cptest&pass=" . $rndpass . "\n" . "https://$ip:2096/login/?user=testing\@cptest.tld&pass=" . $rndpass . "\n\n";
close($etc_motd);

# disables cphulkd
print "disables cphulkd\n";
system_formatted('/usr/local/cpanel/etc/init/stopcphulkd');
system_formatted('/usr/local/cpanel/bin/cphulk_pam_ctl --disable');

# update cplicense
print "updating cpanel license\n";
system_formatted('/usr/local/cpanel/cpkeyclt');

# install CloudLinux
if ( $opts->{'install_cloudlinux'} ) {

    # Remove /var/cpanel/nocloudlinux touch file (if it exists)
    if ( -e ("/var/cpanel/nocloudlinux") ) {
        unlink("/var/cpanel/nocloudlinux");
    }
    system_formatted("wget http://repo.cloudlinux.com/cloudlinux/sources/cln/cldeploy");
    system_formatted("sh cldeploy -k 42-2efe234f2ae327824e879a2bec87fc59");
}

# exit cleanly
print "setup complete\n\n";
system_formatted('cat /etc/motd');
print "\n";
if ( $opts->{'install_cloudlinux'} ) {
    print "CloudLinux installed! A reboot is required!";
}

exit;

### subs
sub print_formatted {
    my @input = split /\n/, $_[0];
    foreach (@input) { print "    $_\n"; }
}

sub system_formatted {
    open( my $cmd, "-|", "$_[0]" );
    while (<$cmd>) {
        print_formatted("$_");
    }
    close $cmd;
}

sub random_pass {
    my $length = shift || 12;

    my $possible = 'abcdefghijkmnpqrstuvwxyz123456789';
    my $string;
    while ( length($string) < $length ) {
        $string .= substr( $possible, ( int( rand( length($possible) ) ) ), 1 );
    }

    return $string;
}

sub usage {
    print <<END_OF_HELP;
Usage: vm_setup.pl [options]

Description: Performs a number of functions to prepare meteorologist VMs for immediate use.

Options:

    --force: Ignores previous run check
    --full: Runs all optional steps.
    --installcl: Installs CloudLinux (requires reboot)

Full list of things this does:

    - Installs common packages
    - Sets hostname
    - Sets resolvers
    - Builds /var/cpanel/cpnat
    - Updates /var/cpanel/cpanel.config (Tweak Settings)
    - Performs basic setup wizard
    - Fixes /etc/hosts
    - Fixes screen permissions
    - Runs cpkeyclt
    - Creates test accounts
    - Disables cphulkd
    - Creates access hash
    - Updates motd
    - Runs upcp (optional, toggle with '--upcp'/'--noupcp')
    - Runs check_cpanel_rpms --fix (optional, toggle with '--check_rpms'/'--nocheck_rpms')
    - Installs Task::Cpanel::Core (optional, toggle with '--install_taskcore'/'--noinstall_taskcore')
END_OF_HELP

    exit;
}

sub enable_everything {
    foreach my $key ( keys %{$opts} ) {
        next if $key =~ m/^(install_cloudlinux|force)$/;
        $opts->{$key} = 1;
    }
    return 1;
}
