package PVE::API2::APT;

use strict;
use warnings;

use POSIX;
use File::stat ();
use IO::File;
use File::Basename;

use LWP::UserAgent;

use PVE::pvecfg;
use PVE::Tools qw(extract_param);
use PVE::Cluster;
use PVE::SafeSyslog;
use PVE::INotify;
use PVE::Exception;
use PVE::RESTHandler;
use PVE::RPCEnvironment;

use JSON;
use PVE::JSONSchema qw(get_standard_option);

use AptPkg::Cache;
use AptPkg::Version;
use AptPkg::PkgRecords;

my $get_apt_cache = sub {
    
    my $apt_cache = AptPkg::Cache->new() || die "unable to initialize AptPkg::Cache\n";

    return $apt_cache;
};

use base qw(PVE::RESTHandler);

__PACKAGE__->register_method({
    name => 'index', 
    path => '', 
    method => 'GET',
    description => "Directory index for apt (Advanced Package Tool).",
    permissions => {
	user => 'all',
    },
    parameters => {
    	additionalProperties => 0,
	properties => {
	    node => get_standard_option('pve-node'),
	},
    },
    returns => {
	type => "array",
	items => {
	    type => "object",
	    properties => {
		id => { type => 'string' },
	    },
	},
	links => [ { rel => 'child', href => "{id}" } ],
    },
    code => sub {
	my ($param) = @_;

	my $res = [ 
	    { id => 'changelog' },
	    { id => 'update' },
	    { id => 'versions' },
	];

	return $res;
    }});

my $get_pkgfile = sub {
    my ($veriter)  = @_;

    foreach my $verfile (@{$veriter->{FileList}}) {
	my $pkgfile = $verfile->{File};
	next if !$pkgfile->{Origin};
	return $pkgfile;
    }

    return undef;
};

my $get_changelog_url =sub {
    my ($pkgname, $info, $pkgver, $origin) = @_;

    my $changelog_url;
    my $base = dirname($info->{FileName});
    if ($origin && $base) {
	$pkgver =~ s/^\d+://; # strip epoch
	my $srcpkg = $info->{SourcePkg} || $pkgname;
	if ($origin eq 'Debian') {
	    $changelog_url = "http://packages.debian.org/changelogs/$base/" . 
		"${srcpkg}_$pkgver/changelog";
	}
    }

    return $changelog_url;
};

my $assemble_pkginfo = sub {
    my ($pkgname, $info, $current_ver, $candidate_ver)  = @_;

    my $data = { 
	Package => $info->{Name},
	Title => $info->{ShortDesc},
	Origin => 'unknown',
    };

    if (my $pkgfile = &$get_pkgfile($candidate_ver)) {
	my $origin = $pkgfile->{Origin};
	$data->{Origin} = $origin;
	if (my $changelog_url = &$get_changelog_url($pkgname, $info, $candidate_ver->{VerStr}, $origin)) {
	    $data->{ChangeLogUrl} = $changelog_url;
	}
    }

    if (my $desc = $info->{LongDesc}) {
	$desc =~ s/^.*\n\s?//; # remove first line
	$desc =~ s/\n / /g;
	$data->{Description} = $desc;
    }
 
    foreach my $k (qw(Section Arch Priority)) {
	$data->{$k} = $candidate_ver->{$k};
    }

    $data->{Version} = $candidate_ver->{VerStr};
    $data->{OldVersion} = $current_ver->{VerStr};

    return $data;
};

# we try to cache results
my $pve_pkgstatus_fn = "/var/lib/pve-manager/pkgupdates";

my $update_pve_pkgstatus = sub {

    syslog('info', "update new package list: $pve_pkgstatus_fn");

    my $pkglist = [];

    my $cache = &$get_apt_cache();
    my $policy = $cache->policy;
    my $pkgrecords = $cache->packages();

    foreach my $pkgname (keys %$cache) {
	my $p = $cache->{$pkgname};
	next if $p->{SelectedState} ne 'Install';
	my $current_ver = $p->{CurrentVer};
	my $candidate_ver = $policy->candidate($p);

	if ($current_ver->{VerStr} ne $candidate_ver->{VerStr}) {
	    my $info = $pkgrecords->lookup($pkgname);
	    my $res = &$assemble_pkginfo($pkgname, $info, $current_ver, $candidate_ver);
	    push @$pkglist, $res;
	}
    }

    PVE::Tools::file_set_contents($pve_pkgstatus_fn, encode_json($pkglist));

    return $pkglist;
};

__PACKAGE__->register_method({
    name => 'list_updates', 
    path => 'update', 
    method => 'GET',
    description => "List available updates.",
    permissions => {
	check => ['perm', '/nodes/{node}', [ 'Sys.Modify' ]],
    },
    protected => 1,
    proxyto => 'node',
    parameters => {
    	additionalProperties => 0,
	properties => {
	    node => get_standard_option('pve-node'),
	},
    },
    returns => {
	type => "array",
	items => {
	    type => "object",
	    properties => {},
	},
    },
    code => sub {
	my ($param) = @_;

	if (my $st1 = File::stat::stat($pve_pkgstatus_fn)) {
	    my $st2 = File::stat::stat("/var/cache/apt/pkgcache.bin");
	    my $st3 = File::stat::stat("/var/lib/dpkg/status");
	
	    if ($st2 && $st3 && $st2->mtime <= $st1->mtime && $st3->mtime <= $st1->mtime) {
		my $data;
		eval {
		    my $jsonstr = PVE::Tools::file_get_contents($pve_pkgstatus_fn, 5*1024*1024);
		    $data = decode_json($jsonstr);
		};
		if (my $err = $@) {
		    warn "error readin cached package status in $pve_pkgstatus_fn\n";
		    # continue and overwrite cache with new content
		} else {
		    return $data;
		}
	    }
	}

	my $pkglist = &$update_pve_pkgstatus();

	return $pkglist;
    }});

__PACKAGE__->register_method({
    name => 'update_database', 
    path => 'update', 
    method => 'POST',
    description => "This is used to resynchronize the package index files from their sources (apt-get update).",
    permissions => {
	check => ['perm', '/nodes/{node}', [ 'Sys.Modify' ]],
    },
    protected => 1,
    proxyto => 'node',
    parameters => {
    	additionalProperties => 0,
	properties => {
	    node => get_standard_option('pve-node'),
	    notify => {
		type => 'boolean',
		description => "Send notification mail about new packages (to email address specified for user 'root\@pam').",
		optional => 1,
		default => 0,
	    },
	},
    },
    returns => {
	type => 'string',
    },
    code => sub {
	my ($param) = @_;

	my $rpcenv = PVE::RPCEnvironment::get();

	my $authuser = $rpcenv->get_user();

	my $realcmd = sub {
	    my $upid = shift;

	    my $cmd = ['apt-get', 'update'];

	    print "starting apt-get update\n";
	    
	    PVE::Tools::run_command($cmd);

	    my $pkglist = &$update_pve_pkgstatus();

	    if ($param->{notify} && scalar(@$pkglist)) {

		my $usercfg = PVE::Cluster::cfs_read_file("user.cfg");
		my $rootcfg = $usercfg->{users}->{'root@pam'} || {};
		my $mailto = $rootcfg->{email};

		if ($mailto) {
		    my $hostname = `hostname -f` || PVE::INotify::nodename();
		    chomp $hostname;

		    my $data = "Content-Type: text/plain;charset=\"UTF8\"\n";
		    $data .= "Content-Transfer-Encoding: 8bit\n";
		    $data .= "FROM: <root\@$hostname>\n";
		    $data .= "TO: $mailto\n";
		    $data .= "SUBJECT: New software packages available ($hostname)\n";
		    $data .= "\n";

		    $data .= "The following updates are available:\n\n";

		    foreach my $p (sort {$a->{Package} cmp $b->{Package} } @$pkglist) {
			$data .= "$p->{Package}: $p->{OldVersion} ==> $p->{Version}\n";
		    }

		    my $fh = IO::File->new("|sendmail -B 8BITMIME $mailto") || 
			die "unable to open 'sendmail' - $!";

		    print $fh $data;

		    $fh->close();
		}
	    }

	    return;
	};

	return $rpcenv->fork_worker('aptupdate', undef, $authuser, $realcmd);

    }});

__PACKAGE__->register_method({
    name => 'changelog', 
    path => 'changelog', 
    method => 'GET',
    description => "Get package changelogs.",
    permissions => {
	check => ['perm', '/nodes/{node}', [ 'Sys.Modify' ]],
    },
    parameters => {
    	additionalProperties => 0,
	properties => {
	    node => get_standard_option('pve-node'),
	    name => {
		description => "Package name.",
		type => 'string',
	    },
	    version => {
		description => "Package version.",
		type => 'string',
		optional => 1,
	    },		
	},
    },
    returns => {
	type => "string",
    },
    code => sub {
	my ($param) = @_;

	my $pkgname = $param->{name};

	my $cache = &$get_apt_cache();
	my $policy = $cache->policy;
	my $p = $cache->{$pkgname} || die "no such package '$pkgname'\n";
	my $pkgrecords = $cache->packages();

	my $ver;
	if ($param->{version}) {
	    if (my $available = $p->{VersionList}) {
		for my $v (@$available) {
		    if ($v->{VerStr} eq $param->{version}) {
			$ver = $v;
			last;
		    }
		}
	    }
	    die "package '$pkgname' version '$param->{version}' is not avalable\n" if !$ver;
	} else {
	    $ver = $policy->candidate($p) || die "no installation candidate for package '$pkgname'\n";
	}

	my $info = $pkgrecords->lookup($pkgname);

	my $pkgfile = &$get_pkgfile($ver);
	my $url;

	die "changelog for '${pkgname}_$ver->{VerStr}' not available\n"
	    if !($pkgfile && ($url = &$get_changelog_url($pkgname, $info, $ver->{VerStr}, $pkgfile->{Origin})));

	my $data = "";

	my $dccfg = PVE::Cluster::cfs_read_file('datacenter.cfg');
	my $proxy = $dccfg->{http_proxy};

	my $ua = LWP::UserAgent->new;
	$ua->agent("PVE/1.0");
	$ua->timeout(10);
	$ua->max_size(1024*1024);
  
	if ($proxy) {
	    $ua->proxy(['http'], $proxy);
	} else {
	    $ua->env_proxy;
	}

	my $response = $ua->get($url);

        if ($response->is_success) {
            $data = $response->decoded_content;
        } else {
	    PVE::Exception::raise($response->message, code => $response->code);
        }

	return $data;
    }});

__PACKAGE__->register_method({
    name => 'versions', 
    path => 'versions', 
    method => 'GET',
    description => "Get package information for important Proxmox packages.",
    permissions => {
	check => ['perm', '/nodes/{node}', [ 'Sys.Audit' ]],
    },
    parameters => {
    	additionalProperties => 0,
	properties => {
	    node => get_standard_option('pve-node'),
	},
    },
    returns => {
	type => "array",
	items => {
	    type => "object",
	    properties => {},
	},
    },
    code => sub {
	my ($param) = @_;

	my $pkgname = $param->{name};

	my $cache = &$get_apt_cache();
	my $policy = $cache->policy;
	my $pkgrecords = $cache->packages();

	# try to use a resonable ordering (most important things first)
	my @list = qw(proxmox-ve-2.6.32 pve-manager);

	foreach my $pkgname (keys %$cache) {
	    if ($pkgname =~ m/pve-kernel-/) {
		my $p = $cache->{$pkgname};
		push @list, $pkgname if $p && $p->{CurrentState} eq 'Installed';
	    }
	}

	push @list, qw(lvm2 clvm corosync-pve openais-pve libqb0 redhat-cluster-pve resource-agents-pve fence-agents-pve pve-cluster qemu-server pve-firmware libpve-common-perl libpve-access-control libpve-storage-perl pve-libspice-server1 vncterm vzctl vzprocps vzquota pve-qemu-kvm ksm-control-daemon);

	my $pkglist = [];
	
	my (undef, undef, $kernel_release) = POSIX::uname();
	my $pvever =  PVE::pvecfg::version_text();

	foreach my $pkgname (@list) {
	    my $p = $cache->{$pkgname};
	    my $info = $pkgrecords->lookup($pkgname);
 	    my $candidate_ver = $policy->candidate($p);
	    my $res;
	    if (my $current_ver = $p->{CurrentVer}) {
		$res = &$assemble_pkginfo($pkgname, $info, $current_ver, 
					  $candidate_ver || $current_ver);
	    } elsif ($candidate_ver) {
		$res = &$assemble_pkginfo($pkgname, $info, $candidate_ver, 
					  $candidate_ver);
		delete $res->{OldVersion};
	    } else {
		next;
	    }
	    $res->{CurrentState} = $p->{CurrentState};

	    # hack: add some useful information (used by 'pveversion -v')
	    if ($pkgname eq 'pve-manager') {
		$res->{ManagerVersion} = $pvever;
	    } elsif ($pkgname eq 'proxmox-ve-2.6.32') {
		$res->{RunningKernel} = $kernel_release;
	    }

	    push @$pkglist, $res;
	}

	return $pkglist;
    }});

1;
