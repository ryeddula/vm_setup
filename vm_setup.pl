#!/usr/bin/perl
# vm_setup
# Utility script to help setup VMs on cPanel VMs.

# Code must be perl v5.8.8 complaint
# to ensure that it can be run on all supported distros.
#
# Do NOT use non-core modules.

use strict;
use warnings;

use Getopt::Long ();
use Fcntl;
$| = 1;

my $VERSION = '0.3.2';
exit run(@ARGV) unless caller;

sub run {
    my @cmdline_args = @_;

    print "\n[*] VM Server Setup Script\n";
    print "[*] Version: $VERSION\n\n";

    # get opts
    my $opts = _parse_opts( \@cmdline_args );
    my $has_cpanel = -x '/usr/local/cpanel/cpanel' ? 1 : 0;
    lock_check( $opts->{'force'} ) or return 1;

    install_common_utils() or return 1;
    fix_screen_perms()     or return 1;
    set_hostname_and_network( $opts->{'sub'}->{'hostname'}, $has_cpanel ) or return 1;
    fix_resolve_conf() or return 1;

    my $public_ip = _get_public_ip($has_cpanel) or return 1;
    fix_hosts_file( $public_ip, $opts->{'sub'}->{'hostname'} ) or return 1;

    my $cat_motd = 0;
    if ($has_cpanel) {
        fix_cpanel_conf_files( $opts->{'sub'}->{'hostname'} ) or return 1;
        setup_demo_accts($public_ip)                          or return 1;
        run_post_opts($opts)                                  or return 1;
        install_cpanel_crontab()                              or return 1;

        # disables cphulkd
        print "[*] Disable cphulkd...\n";
        system_formatted('/usr/local/cpanel/etc/init/stopcphulkd');
        system_formatted('/usr/local/cpanel/bin/cphulk_pam_ctl --disable');

        # update cplicense
        print "[*] Updating cpanel license\n";
        system_formatted('/usr/local/cpanel/cpkeyclt');
        $cat_motd = 1;
    }

    if ( $opts->{'install_cloudlinux'} ) {

        # Remove /var/cpanel/nocloudlinux touch file (if it exists)
        if ( -e ("/var/cpanel/nocloudlinux") ) {
            unlink("/var/cpanel/nocloudlinux");
        }
        system_formatted("wget http://repo.cloudlinux.com/cloudlinux/sources/cln/cldeploy");
        system_formatted("sh cldeploy -k 42-2efe234f2ae327824e879a2bec87fc59");
    }

    # exit cleanly
    print "[+] Setup complete\n\n";
    system_formatted('cat /etc/motd') if $cat_motd;
    print "\n";
    if ( $opts->{'install_cloudlinux'} ) {
        print "[!!!!!] CloudLinux installed! A reboot is required!";
    }

    return 0;
}

sub install_common_utils {
    print "[*] Installing common utilities via yum [vim-enhanced mtr nmap telnet nc jq s3cmd bind-utils jwhois dev git]\n";
    system_formatted("yum -y install vim-enhanced mtr nmap telnet nc jq s3cmd bind-utils jwhois dev git");
    return 1;
}

sub fix_screen_perms {
    print "[*] Fixing screen perms\n";
    system_formatted('rpm --setperms screen');
    return 1;
}

sub set_hostname_and_network {
    my ( $hostname, $has_cpanel ) = @_;

    print "[*] Setting hostname...\n";
    if ($has_cpanel) {
        system_formatted("/usr/local/cpanel/bin/set_hostname $hostname");
    }
    else {
        system_formatted("hostname $hostname");
        sysopen( my $etc_hostname, '/etc/hostname', O_WRONLY | O_CREAT )
          or die print_formatted("$!");
        print $etc_hostname "$hostname";
        close($etc_hostname);

        # set /etc/sysconfig/network
        print "updating /etc/sysconfig/network\n";
        unlink '/etc/sysconfig/network';
        sysopen( my $etc_network, '/etc/sysconfig/network', O_WRONLY | O_CREAT )
          or die print_formatted("$!");
        print $etc_network "NETWORKING=yes\n" . "NOZEROCONF=yes\n" . "HOSTNAME=" . $hostname . "\n";
        close($etc_network);
    }
    return 1;
}

sub fix_resolve_conf {
    print "[*] Fixing resolv.conf...\n";
    unlink '/etc/resolv.conf';
    sysopen( my $etc_resolv_conf, '/etc/resolv.conf', O_WRONLY | O_CREAT )
      or die print_formatted("$!");
    print $etc_resolv_conf "search cpanel.net\n" . "nameserver 208.74.121.103\n";
    close($etc_resolv_conf);
    return 1;
}

sub fix_hosts_file {
    my ( $ip, $hostname ) = @_;

    print "[*] Fixing /etc/hosts\n";
    if ( !$ip ) {
        return;
    }

    unlink '/etc/hosts';
    sysopen( my $etc_hosts, '/etc/hosts', O_WRONLY | O_CREAT )
      or die print_formatted("$!");
    print $etc_hosts "127.0.0.1		localhost localhost.localdomain localhost4 localhost4.localdomain4\n" . "::1		localhost localhost.localdomain localhost6 localhost6.localdomain6\n" . "$ip		$hostname\n";
    close($etc_hosts);
    return 1;
}

sub fix_cpanel_conf_files {
    my $hostname = shift;

    chomp( my $natip = qx(cat /var/cpanel/cpnat | awk '{print\$1}') );
    print "[*] Creating /etc/.whostmgrft\n";
    sysopen( my $etc_whostmgrft, '/etc/.whostmgrft', O_WRONLY | O_CREAT )
      or die print_formatted("$!");
    close($etc_whostmgrft);

    # correct wwwacct.conf
    print "[*] Correcting /etc/wwwacct.conf\n";
    unlink '/etc/wwwacct.conf';
    my $OSVER  = `cat /etc/redhat-release`;
    my $MINUID = 500;
    if ( $OSVER =~ 7.1 ) {
        $MINUID = 1000;
    }
    sysopen( my $etc_wwwacct_conf, '/etc/wwwacct.conf', O_WRONLY | O_CREAT )
      or die print_formatted("$!");
    print $etc_wwwacct_conf "HOST $hostname\n"
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

    # make accesshash
    print "making access hash\n";
    $ENV{'REMOTE_USER'} = 'root';
    system_formatted('/usr/local/cpanel/bin/realmkaccesshash');
}

sub setup_demo_accts {
    my $ip = shift;
    my $rndpass = random_pass(12);

    print "[*] Creating test account - cptest\n";
    system_formatted( 'yes |/scripts/wwwacct cptest.tld cptest ' . $rndpass . ' 1000 paper_lantern n y 10 10 10 10 10 10 10 n' );
    print "[*] Creating test email - testing\@cptest.tld\n";
    system_formatted( '/scripts/addpop testing@cptest.tld ' . $rndpass );
    print "[*] Creating test database - cptest_testdb\n";
    system_formatted("mysql -e 'create database cptest_testdb'");
    print "[*] Creating test db user - cptest_testuser\n";
    system_formatted("mysql -e 'create user \"cptest_testuser\" identified by \" $rndpass \"'");
    print "[*] Adding all privs for cptest_testuser to cptest_testdb\n";
    system_formatted("mysql -e 'grant all on cptest_testdb.* TO cptest_testuser'");
    system_formatted("mysql -e 'FLUSH PRIVILEGES'");
    print "[*] Mapping cptest_testuser and cptest_testdb to cptest account\n";
    system_formatted("/usr/local/cpanel/bin/dbmaptool cptest --type mysql --dbusers 'cptest_testuser' --dbs 'cptest_testdb'");

    print "[*] Updating tweak settings (cpanel.config)...\n";
    system_formatted("/usr/bin/replace allowremotedomains=0 allowremotedomains=1 allowunregistereddomains=0 allowunregistereddomains=1 -- /var/cpanel/cpanel.config");

    print "[*] Updating /etc/motd\n";
    unlink '/etc/motd';
    sysopen( my $etc_motd, '/etc/motd', O_WRONLY | O_CREAT )
      or die print_formatted("$!");
    print $etc_motd "\nVM Setup Script created the following test accounts:\n" . "https://$ip:2087/login/?user=root&pass=cpanel1\n" . "https://$ip:2083/login/?user=cptest&pass=" . $rndpass . "\n" . "https://$ip:2096/login/?user=testing\@cptest.tld&pass=" . $rndpass . "\n\n";
    close($etc_motd);

    return 1;
}

sub run_post_opts {
    my $opts = shift;

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
    return 1;
}

sub install_cpanel_crontab {
    if ( !-s "/var/spool/cron/root" ) {
        print "[*] Installing root's cPanel crontab... \n";
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
    return 1;
}

sub lock_check {
    my $force = shift;
    if ( -e "/root/vmsetup.lock" ) {
        if ( !$force ) {
            print "[!] /root/vmsetup.lock exists. This script may have already been run. Use --force to bypass. Exiting...\n";
            return;
        }
    }

    # create lock file
    print "[*] Creating lock file\n";
    system_formatted("touch /root/vmsetup.lock");
    return 1;
}

sub _get_public_ip {
    my $has_cpanel = shift;

    my $ip;
    if ($has_cpanel) {
        print "running build_cpnat\n";
        system_formatted("/scripts/build_cpnat");
        chomp( $ip = qx(cat /var/cpanel/cpnat | awk '{print\$2}') );
    }
    else {
    }

    if ( !$ip ) {
        print "[!] Failed to determine public IP.\n";
        return;
    }
    return $ip;
}

sub _parse_opts {
    my $cmdline_args = shift;

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

    my $enable_everything = sub {
        foreach my $key ( keys %{$opts} ) {
            next if $key =~ m/^(install_cloudlinux|force)$/;
            $opts->{$key} = 1;
        }
        return 1;
    };

    Getopt::Long::GetOptionsFromArray(
        $cmdline_args,
        'help'             => \&usage,
        'full'             => $enable_everything,
        'force'            => \$opts->{'force'},
        'installcl'        => \$opts->{'install_cloudlinux'},
        'upcp!'            => \$opts->{'run_upcp'},
        'check_rpms!'      => \$opts->{'run_check_cpanel_rpms'},
        'install_taskcore' => \$opts->{'install_task_cpanel_core'},

        # Optional configuration options:
        'hostname=s'      => \$opts->{'sub'}->{'hostname'},
        'metadata_host=s' => \$opts->{'sub'}->{'metadata_host'},
    );

    return $opts;
}

# install CloudLinux

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
    my $length //= 12;

    my $possible = 'abcdefghijkmnpqrstuvwxyz123456789';
    my $string   = '';
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
