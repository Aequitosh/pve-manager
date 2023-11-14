package PVE::API2::Cluster::Notifications;

use warnings;
use strict;

use Storable qw(dclone);
use JSON;

use PVE::Exception qw(raise_param_exc);
use PVE::Tools qw(extract_param);
use PVE::JSONSchema qw(get_standard_option);
use PVE::RESTHandler;
use PVE::Notify;

use base qw(PVE::RESTHandler);

sub make_properties_optional {
    my ($properties) = @_;
    $properties = dclone($properties);

    for my $key (keys %$properties) {
	$properties->{$key}->{optional} = 1 if $key ne 'name';
    }

    return $properties;
}

sub remove_protected_properties {
    my ($properties, $to_remove) = @_;
    $properties = dclone($properties);

    for my $key (keys %$properties) {
	if (grep /^$key$/, @$to_remove) {
	    delete $properties->{$key};
	}
    }

    return $properties;
}

sub raise_api_error {
    my ($api_error) = @_;

    if (!(ref($api_error) eq 'HASH' && $api_error->{message} && $api_error->{code})) {
	die $api_error;
    }

    my $msg = "$api_error->{message}\n";
    my $exc = PVE::Exception->new($msg, code => $api_error->{code});

    my (undef, $filename, $line) = caller;

    $exc->{filename} = $filename;
    $exc->{line} = $line;

    die $exc;
}

sub filter_entities_by_privs {
    my ($rpcenv, $entities) = @_;
    my $authuser = $rpcenv->get_user();

    my $can_see_mapping_privs = ['Mapping.Modify', 'Mapping.Use', 'Mapping.Audit'];

    my $filtered = [grep {
	$rpcenv->check_any(
	    $authuser,
	    "/mapping/notification/$_->{name}",
	    $can_see_mapping_privs,
	    1
	);
    } @$entities];

    return $filtered;
}

__PACKAGE__->register_method ({
    name => 'index',
    path => '',
    method => 'GET',
    description => 'Index for notification-related API endpoints.',
    permissions => { user => 'all' },
    parameters => {
	additionalProperties => 0,
	properties => {},
    },
    returns => {
	type => 'array',
	items => {
	    type => 'object',
	    properties => {},
	},
	links => [ { rel => 'child', href => '{name}' } ],
    },
    code => sub {
	my $result = [
	    { name => 'endpoints' },
	    { name => 'matchers' },
	    { name => 'targets' },
	];

	return $result;
    }
});

__PACKAGE__->register_method ({
    name => 'endpoints_index',
    path => 'endpoints',
    method => 'GET',
    description => 'Index for all available endpoint types.',
    permissions => { user => 'all' },
    parameters => {
	additionalProperties => 0,
	properties => {},
    },
    returns => {
	type => 'array',
	items => {
	    type => 'object',
	    properties => {},
	},
	links => [ { rel => 'child', href => '{name}' } ],
    },
    code => sub {
	my $result = [
	    { name => 'gotify' },
	    { name => 'sendmail' },
	];

	return $result;
    }
});

__PACKAGE__->register_method ({
    name => 'get_all_targets',
    path => 'targets',
    method => 'GET',
    description => 'Returns a list of all entities that can be used as notification targets.',
    permissions => {
	description => "Only lists entries where you have 'Mapping.Modify', 'Mapping.Use' or"
	    . " 'Mapping.Audit' permissions on '/mapping/notification/<name>'."
	    . " The special 'mail-to-root' target is available to all users.",
	user => 'all',
    },
    protected => 1,
    parameters => {
	additionalProperties => 0,
	properties => {},
    },
    returns => {
	type => 'array',
	items => {
	    type => 'object',
	    properties => {
		name => {
		    description => 'Name of the target.',
		    type => 'string',
		    format => 'pve-configid',
		},
		'type' => {
		    description => 'Type of the target.',
		    type  => 'string',
		    enum => [qw(sendmail gotify)],
		},
		'comment' => {
		    description => 'Comment',
		    type        => 'string',
		    optional    => 1,
		},
	    },
	},
	links => [ { rel => 'child', href => '{name}' } ],
    },
    code => sub {
	my $config = PVE::Notify::read_config();
	my $rpcenv = PVE::RPCEnvironment::get();

	my $targets = eval {
	    my $result = [];

	    for my $target (@{$config->get_sendmail_endpoints()}) {
		push @$result, {
		    name => $target->{name},
		    comment => $target->{comment},
		    type => 'sendmail',
		};
	    }

	    for my $target (@{$config->get_gotify_endpoints()}) {
		push @$result, {
		    name => $target->{name},
		    comment => $target->{comment},
		    type => 'gotify',
		};
	    }

	    for my $target (@{$config->get_smtp_endpoints()}) {
		push @$result, {
		    name => $target->{name},
		    comment => $target->{comment},
		    type => 'smtp',
		};
	    }

	    $result
	};

	raise_api_error($@) if $@;

	return filter_entities_by_privs($rpcenv, $targets);
    }
});

__PACKAGE__->register_method ({
    name => 'test_target',
    path => 'targets/{name}/test',
    protected => 1,
    method => 'POST',
    description => 'Send a test notification to a provided target.',
    permissions => {
	description => "The user requires 'Mapping.Modify', 'Mapping.Use' or"
	    . " 'Mapping.Audit' permissions on '/mapping/notification/<name>'."
	    . " The special 'mail-to-root' target can be accessed by all users.",
	user => 'all',
    },
    parameters => {
	additionalProperties => 0,
	properties => {
	    name => {
		description => 'Name of the target.',
		type => 'string',
		format => 'pve-configid'
	    },
	},
    },
    returns => { type => 'null' },
    code => sub {
	my ($param) = @_;
	my $name = extract_param($param, 'name');
	my $rpcenv = PVE::RPCEnvironment::get();
	my $authuser = $rpcenv->get_user();

	my $privs = ['Mapping.Modify', 'Mapping.Use', 'Mapping.Audit'];

	$rpcenv->check_any(
	    $authuser,
	    "/mapping/notification/$name",
	    $privs,
	);

	eval {
	    my $config = PVE::Notify::read_config();
	    $config->test_target($name);
	};

	raise_api_error($@) if $@;

	return;
    }
});

my $sendmail_properties = {
    name => {
	description => 'The name of the endpoint.',
	type => 'string',
	format => 'pve-configid',
    },
    mailto => {
	type => 'array',
	items => {
	    type => 'string',
	    format => 'email-or-username',
	},
	description => 'List of email recipients',
	optional => 1,
    },
    'mailto-user' => {
	type => 'array',
	items => {
	    type => 'string',
	    format => 'pve-userid',
	},
	description => 'List of users',
	optional => 1,
    },
    'from-address' => {
	description => '`From` address for the mail',
	type => 'string',
	optional => 1,
    },
    author => {
	description => 'Author of the mail',
	type => 'string',
	optional => 1,
    },
    'comment' => {
	description => 'Comment',
	type        => 'string',
	optional    => 1,
    },
};

__PACKAGE__->register_method ({
    name => 'get_sendmail_endpoints',
    path => 'endpoints/sendmail',
    method => 'GET',
    description => 'Returns a list of all sendmail endpoints',
    permissions => {
	description => "Only lists entries where you have 'Mapping.Modify', 'Mapping.Use' or"
	    . " 'Mapping.Audit' permissions on '/mapping/notification/<name>'.",
	user => 'all',
    },
    protected => 1,
    parameters => {
	additionalProperties => 0,
	properties => {},
    },
    returns => {
	type => 'array',
	items => {
	    type => 'object',
	    properties => $sendmail_properties,
	},
	links => [ { rel => 'child', href => '{name}' } ],
    },
    code => sub {
	my $config = PVE::Notify::read_config();
	my $rpcenv = PVE::RPCEnvironment::get();

	my $entities = eval {
	    $config->get_sendmail_endpoints();
	};
	raise_api_error($@) if $@;

	return filter_entities_by_privs($rpcenv, $entities);
    }
});

__PACKAGE__->register_method ({
    name => 'get_sendmail_endpoint',
    path => 'endpoints/sendmail/{name}',
    method => 'GET',
    description => 'Return a specific sendmail endpoint',
    permissions => {
	check => ['or',
	    ['perm', '/mapping/notification/{name}', ['Mapping.Modify']],
	    ['perm', '/mapping/notification/{name}', ['Mapping.Audit']],
	],
    },
    protected => 1,
    parameters => {
	additionalProperties => 0,
	properties => {
	    name => {
		type => 'string',
		format => 'pve-configid',
	    },
	}
    },
    returns => {
	type => 'object',
	properties => {
	    %$sendmail_properties,
	    digest => get_standard_option('pve-config-digest'),
	}

    },
    code => sub {
	my ($param) = @_;
	my $name = extract_param($param, 'name');

	my $config = PVE::Notify::read_config();
	my $endpoint = eval {
	    $config->get_sendmail_endpoint($name)
	};

	raise_api_error($@) if $@;
	$endpoint->{digest} = $config->digest();

	return $endpoint;
    }
});

__PACKAGE__->register_method ({
    name => 'create_sendmail_endpoint',
    path => 'endpoints/sendmail',
    protected => 1,
    method => 'POST',
    description => 'Create a new sendmail endpoint',
    permissions => {
	check => ['perm', '/mapping/notification', ['Mapping.Modify']],
    },
    parameters => {
	additionalProperties => 0,
	properties => $sendmail_properties,
    },
    returns => { type => 'null' },
    code => sub {
	my ($param) = @_;

	my $name = extract_param($param, 'name');
	my $mailto = extract_param($param, 'mailto');
	my $mailto_user = extract_param($param, 'mailto-user');
	my $from_address = extract_param($param, 'from-address');
	my $author = extract_param($param, 'author');
	my $comment = extract_param($param, 'comment');

	eval {
	    PVE::Notify::lock_config(sub {
		my $config = PVE::Notify::read_config();

		$config->add_sendmail_endpoint(
		    $name,
		    $mailto,
		    $mailto_user,
		    $from_address,
		    $author,
		    $comment,
		);

		PVE::Notify::write_config($config);
	    });
	};

	raise_api_error($@) if $@;
	return;
    }
});

__PACKAGE__->register_method ({
    name => 'update_sendmail_endpoint',
    path => 'endpoints/sendmail/{name}',
    protected => 1,
    method => 'PUT',
    description => 'Update existing sendmail endpoint',
    permissions => {
	check => ['perm', '/mapping/notification/{name}', ['Mapping.Modify']],
    },
    parameters => {
	additionalProperties => 0,
	properties => {
	    %{ make_properties_optional($sendmail_properties) },
	    delete => {
		type => 'array',
		items => {
		    type => 'string',
		    format => 'pve-configid',
		},
		optional => 1,
		description => 'A list of settings you want to delete.',
	    },
	    digest => get_standard_option('pve-config-digest'),

	}
    },
    returns => { type => 'null' },
    code => sub {
	my ($param) = @_;

	my $name = extract_param($param, 'name');
	my $mailto = extract_param($param, 'mailto');
	my $mailto_user = extract_param($param, 'mailto-user');
	my $from_address = extract_param($param, 'from-address');
	my $author = extract_param($param, 'author');
	my $comment = extract_param($param, 'comment');

	my $delete = extract_param($param, 'delete');
	my $digest = extract_param($param, 'digest');

	eval {
	    PVE::Notify::lock_config(sub {
		my $config = PVE::Notify::read_config();

		$config->update_sendmail_endpoint(
		    $name,
		    $mailto,
		    $mailto_user,
		    $from_address,
		    $author,
		    $comment,
		    $delete,
		    $digest,
		);

		PVE::Notify::write_config($config);
	    });
	};

	raise_api_error($@) if $@;
	return;
    }
});

__PACKAGE__->register_method ({
    name => 'delete_sendmail_endpoint',
    protected => 1,
    path => 'endpoints/sendmail/{name}',
    method => 'DELETE',
    description => 'Remove sendmail endpoint',
    permissions => {
	check => ['perm', '/mapping/notification', ['Mapping.Modify']],
    },
    parameters => {
	additionalProperties => 0,
	properties => {
	    name => {
		type => 'string',
		format => 'pve-configid',
	    },
	}
    },
    returns => { type => 'null' },
    code => sub {
	my ($param) = @_;
	my $name = extract_param($param, 'name');

	eval {
	    PVE::Notify::lock_config(sub {
		my $config = PVE::Notify::read_config();
		$config->delete_sendmail_endpoint($name);
		PVE::Notify::write_config($config);
	    });
	};

	raise_api_error($@) if ($@);
	return;
    }
});

my $gotify_properties = {
    name => {
	description => 'The name of the endpoint.',
	type => 'string',
	format => 'pve-configid',
    },
    'server' => {
	description => 'Server URL',
	type => 'string',
    },
    'token' => {
	description => 'Secret token',
	type => 'string',
    },
    'comment' => {
	description => 'Comment',
	type        => 'string',
	optional    => 1,
    },
};

__PACKAGE__->register_method ({
    name => 'get_gotify_endpoints',
    path => 'endpoints/gotify',
    method => 'GET',
    description => 'Returns a list of all gotify endpoints',
    protected => 1,
    permissions => {
	description => "Only lists entries where you have 'Mapping.Modify', 'Mapping.Use' or"
	    . " 'Mapping.Audit' permissions on '/mapping/notification/<name>'.",
	user => 'all',
    },
    parameters => {
	additionalProperties => 0,
	properties => {},
    },
    returns => {
	type => 'array',
	items => {
	    type => 'object',
	    properties => remove_protected_properties($gotify_properties, ['token']),
	},
	links => [ { rel => 'child', href => '{name}' } ],
    },
    code => sub {
	my $config = PVE::Notify::read_config();
	my $rpcenv = PVE::RPCEnvironment::get();

	my $entities = eval {
	    $config->get_gotify_endpoints();
	};
	raise_api_error($@) if $@;

	return filter_entities_by_privs($rpcenv, $entities);
    }
});

__PACKAGE__->register_method ({
    name => 'get_gotify_endpoint',
    path => 'endpoints/gotify/{name}',
    method => 'GET',
    description => 'Return a specific gotify endpoint',
    protected => 1,
    permissions => {
	check => ['or',
	    ['perm', '/mapping/notification/{name}', ['Mapping.Modify']],
	    ['perm', '/mapping/notification/{name}', ['Mapping.Audit']],
	],
    },
    parameters => {
	additionalProperties => 0,
	properties => {
	    name => {
		type => 'string',
		format => 'pve-configid',
		description => 'Name of the endpoint.'
	    },
	}
    },
    returns => {
	type => 'object',
	properties => {
	    %{ remove_protected_properties($gotify_properties, ['token']) },
	    digest => get_standard_option('pve-config-digest'),
	}
    },
    code => sub {
	my ($param) = @_;
	my $name = extract_param($param, 'name');

	my $config = PVE::Notify::read_config();
	my $endpoint = eval {
	    $config->get_gotify_endpoint($name)
	};

	raise_api_error($@) if $@;
	$endpoint->{digest} = $config->digest();

	return $endpoint;
    }
});

__PACKAGE__->register_method ({
    name => 'create_gotify_endpoint',
    path => 'endpoints/gotify',
    protected => 1,
    method => 'POST',
    description => 'Create a new gotify endpoint',
    permissions => {
	check => ['perm', '/mapping/notification', ['Mapping.Modify']],
    },
    parameters => {
	additionalProperties => 0,
	properties => $gotify_properties,
    },
    returns => { type => 'null' },
    code => sub {
	my ($param) = @_;

	my $name = extract_param($param, 'name');
	my $server = extract_param($param, 'server');
	my $token = extract_param($param, 'token');
	my $comment = extract_param($param, 'comment');

	eval {
	    PVE::Notify::lock_config(sub {
		my $config = PVE::Notify::read_config();

		$config->add_gotify_endpoint(
		    $name,
		    $server,
		    $token,
		    $comment,
		);

		PVE::Notify::write_config($config);
	    });
	};

	raise_api_error($@) if $@;
	return;
    }
});

__PACKAGE__->register_method ({
    name => 'update_gotify_endpoint',
    path => 'endpoints/gotify/{name}',
    protected => 1,
    method => 'PUT',
    description => 'Update existing gotify endpoint',
    permissions => {
	check => ['perm', '/mapping/notification/{name}', ['Mapping.Modify']],
    },
    parameters => {
	additionalProperties => 0,
	properties => {
	    %{ make_properties_optional($gotify_properties) },
	    delete => {
		type => 'array',
		items => {
		    type => 'string',
		    format => 'pve-configid',
		},
		optional => 1,
		description => 'A list of settings you want to delete.',
	    },
	    digest => get_standard_option('pve-config-digest'),
	}
    },
    returns => { type => 'null' },
    code => sub {
	my ($param) = @_;

	my $name = extract_param($param, 'name');
	my $server = extract_param($param, 'server');
	my $token = extract_param($param, 'token');
	my $comment = extract_param($param, 'comment');

	my $delete = extract_param($param, 'delete');
	my $digest = extract_param($param, 'digest');

	eval {
	    PVE::Notify::lock_config(sub {
		my $config = PVE::Notify::read_config();

		$config->update_gotify_endpoint(
		    $name,
		    $server,
		    $token,
		    $comment,
		    $delete,
		    $digest,
		);

		PVE::Notify::write_config($config);
	    });
	};

	raise_api_error($@) if $@;
	return;
    }
});

__PACKAGE__->register_method ({
    name => 'delete_gotify_endpoint',
    protected => 1,
    path => 'endpoints/gotify/{name}',
    method => 'DELETE',
    description => 'Remove gotify endpoint',
    permissions => {
	check => ['perm', '/mapping/notification/{name}', ['Mapping.Modify']],
    },
    parameters => {
	additionalProperties => 0,
	properties => {
	    name => {
		type => 'string',
		format => 'pve-configid',
	    },
	}
    },
    returns => { type => 'null' },
    code => sub {
	my ($param) = @_;
	my $name = extract_param($param, 'name');

	eval {
	    PVE::Notify::lock_config(sub {
		my $config = PVE::Notify::read_config();
		$config->delete_gotify_endpoint($name);
		PVE::Notify::write_config($config);
	    });
	};

	raise_api_error($@) if $@;
	return;
    }
});

my $smtp_properties= {
    name => {
	description => 'The name of the endpoint.',
	type => 'string',
	format => 'pve-configid',
    },
    server => {
	description => 'The address of the SMTP server.',
	type => 'string',
    },
    port => {
	description => 'The port to be used. Defaults to 465 for TLS based connections,'
	    . ' 587 for STARTTLS based connections and port 25 for insecure plain-text'
	    . ' connections.',
	type => 'integer',
	optional => 1,
    },
    mode => {
	description => 'Determine which encryption method shall be used for the connection.',
	type => 'string',
	enum => [ qw(insecure starttls tls) ],
	default => 'tls',
	optional => 1,
    },
    username => {
	description => 'Username for SMTP authentication',
	type => 'string',
	optional => 1,
    },
    password => {
	description => 'Password for SMTP authentication',
	type => 'string',
	optional => 1,
    },
    mailto => {
	type => 'array',
	items => {
	    type => 'string',
	    format => 'email-or-username',
	},
	description => 'List of email recipients',
	optional => 1,
    },
    'mailto-user' => {
	type => 'array',
	items => {
	    type => 'string',
	    format => 'pve-userid',
	},
	description => 'List of users',
	optional => 1,
    },
    'from-address' => {
	description => '`From` address for the mail',
	type => 'string',
    },
    author => {
	description => 'Author of the mail. Defaults to \'Proxmox VE\'.',
	type => 'string',
	optional => 1,
    },
    'comment' => {
	description => 'Comment',
	type        => 'string',
	optional    => 1,
    },
};

__PACKAGE__->register_method ({
    name => 'get_smtp_endpoints',
    path => 'endpoints/smtp',
    method => 'GET',
    description => 'Returns a list of all smtp endpoints',
    permissions => {
	description => "Only lists entries where you have 'Mapping.Modify', 'Mapping.Use' or"
	    . " 'Mapping.Audit' permissions on '/mapping/notification/targets/<name>'.",
	user => 'all',
    },
    protected => 1,
    parameters => {
	additionalProperties => 0,
	properties => {},
    },
    returns => {
	type => 'array',
	items => {
	    type => 'object',
	    properties => $smtp_properties,
	},
	links => [ { rel => 'child', href => '{name}' } ],
    },
    code => sub {
	my $config = PVE::Notify::read_config();
	my $rpcenv = PVE::RPCEnvironment::get();

	my $entities = eval {
	    $config->get_smtp_endpoints();
	};
	raise_api_error($@) if $@;

	return filter_entities_by_privs($rpcenv, "targets", $entities);
    }
});

__PACKAGE__->register_method ({
    name => 'get_smtp_endpoint',
    path => 'endpoints/smtp/{name}',
    method => 'GET',
    description => 'Return a specific smtp endpoint',
    permissions => {
	check => ['or',
	    ['perm', '/mapping/notification/targets/{name}', ['Mapping.Modify']],
	    ['perm', '/mapping/notification/targets/{name}', ['Mapping.Audit']],
	],
    },
    protected => 1,
    parameters => {
	additionalProperties => 0,
	properties => {
	    name => {
		type => 'string',
		format => 'pve-configid',
	    },
	}
    },
    returns => {
	type => 'object',
	properties => {
	    %{ remove_protected_properties($smtp_properties, ['password']) },
	    digest => get_standard_option('pve-config-digest'),
	}

    },
    code => sub {
	my ($param) = @_;
	my $name = extract_param($param, 'name');

	my $config = PVE::Notify::read_config();
	my $endpoint = eval {
	    $config->get_smtp_endpoint($name)
	};

	raise_api_error($@) if $@;
	$endpoint->{digest} = $config->digest();

	return $endpoint;
    }
});

__PACKAGE__->register_method ({
    name => 'create_smtp_endpoint',
    path => 'endpoints/smtp',
    protected => 1,
    method => 'POST',
    description => 'Create a new smtp endpoint',
    permissions => {
	check => ['perm', '/mapping/notification/targets', ['Mapping.Modify']],
    },
    parameters => {
	additionalProperties => 0,
	properties => $smtp_properties,
    },
    returns => { type => 'null' },
    code => sub {
	my ($param) = @_;

	my $name = extract_param($param, 'name');
	my $server = extract_param($param, 'server');
	my $port = extract_param($param, 'port');
	my $mode = extract_param($param, 'mode');
	my $username = extract_param($param, 'username');
	my $password = extract_param($param, 'password');
	my $mailto = extract_param($param, 'mailto');
	my $mailto_user = extract_param($param, 'mailto-user');
	my $from_address = extract_param($param, 'from-address');
	my $author = extract_param($param, 'author');
	my $comment = extract_param($param, 'comment');

	eval {
	    PVE::Notify::lock_config(sub {
		my $config = PVE::Notify::read_config();

		$config->add_smtp_endpoint(
		    $name,
		    $server,
		    $port,
		    $mode,
		    $username,
		    $password,
		    $mailto,
		    $mailto_user,
		    $from_address,
		    $author,
		    $comment,
		);

		PVE::Notify::write_config($config);
	    });
	};

	raise_api_error($@) if $@;
	return;
    }
});

__PACKAGE__->register_method ({
    name => 'update_smtp_endpoint',
    path => 'endpoints/smtp/{name}',
    protected => 1,
    method => 'PUT',
    description => 'Update existing smtp endpoint',
    permissions => {
	check => ['perm', '/mapping/notification/targets/{name}', ['Mapping.Modify']],
    },
    parameters => {
	additionalProperties => 0,
	properties => {
	    %{ make_properties_optional($smtp_properties) },
	    delete => {
		type => 'array',
		items => {
		    type => 'string',
		    format => 'pve-configid',
		},
		optional => 1,
		description => 'A list of settings you want to delete.',
	    },
	    digest => get_standard_option('pve-config-digest'),

	}
    },
    returns => { type => 'null' },
    code => sub {
	my ($param) = @_;

	my $name = extract_param($param, 'name');
	my $server = extract_param($param, 'server');
	my $port = extract_param($param, 'port');
	my $mode = extract_param($param, 'mode');
	my $username = extract_param($param, 'username');
	my $password = extract_param($param, 'password');
	my $mailto = extract_param($param, 'mailto');
	my $mailto_user = extract_param($param, 'mailto-user');
	my $from_address = extract_param($param, 'from-address');
	my $author = extract_param($param, 'author');
	my $comment = extract_param($param, 'comment');

	my $delete = extract_param($param, 'delete');
	my $digest = extract_param($param, 'digest');

	eval {
	    PVE::Notify::lock_config(sub {
		my $config = PVE::Notify::read_config();

		$config->update_smtp_endpoint(
		    $name,
		    $server,
		    $port,
		    $mode,
		    $username,
		    $password,
		    $mailto,
		    $mailto_user,
		    $from_address,
		    $author,
		    $comment,
		    $delete,
		    $digest,
		);

		PVE::Notify::write_config($config);
	    });
	};

	raise_api_error($@) if $@;
	return;
    }
});

__PACKAGE__->register_method ({
    name => 'delete_smtp_endpoint',
    protected => 1,
    path => 'endpoints/smtp/{name}',
    method => 'DELETE',
    description => 'Remove smtp endpoint',
    permissions => {
	check => ['perm', '/mapping/notification/targets/{name}', ['Mapping.Modify']],
    },
    parameters => {
	additionalProperties => 0,
	properties => {
	    name => {
		type => 'string',
		format => 'pve-configid',
	    },
	}
    },
    returns => { type => 'null' },
    code => sub {
	my ($param) = @_;
	my $name = extract_param($param, 'name');

	eval {
	    PVE::Notify::lock_config(sub {
		my $config = PVE::Notify::read_config();
		$config->delete_smtp_endpoint($name);
		PVE::Notify::write_config($config);
	    });
	};

	raise_api_error($@) if ($@);
	return;
    }
});

my $matcher_properties = {
    name => {
	description => 'Name of the matcher.',
	type => 'string',
	format => 'pve-configid',
    },
    'match-field' => {
	type => 'array',
	items => {
	    type => 'string',
	},
	optional => 1,
	description => 'Metadata fields to match (regex or exact match).'
	    . ' Must be in the form (regex|exact):<field>=<value>',
    },
    'match-severity' => {
	type => 'array',
	items => {
	    type => 'string',
	},
	optional => 1,
	description => 'Notification severities to match',
    },
    'match-calendar' => {
	type => 'array',
	items => {
	    type => 'string',
	},
	optional => 1,
	description => 'Match notification timestamp',
    },
    'target' => {
	type => 'array',
	items => {
	    type => 'string',
	    format => 'pve-configid',
	},
	optional => 1,
	description => 'Targets to notify on match',
    },
    mode => {
	type => 'string',
	description => "Choose between 'all' and 'any' for when multiple properties are specified",
	optional => 1,
	enum => [qw(all any)],
	default => 'all',
    },
    'invert-match' => {
	type => 'boolean',
	description => 'Invert match of the whole matcher',
	optional => 1,
    },
    'comment' => {
	description => 'Comment',
	type        => 'string',
	optional    => 1,
    },
};

__PACKAGE__->register_method ({
    name => 'get_matchers',
    path => 'matchers',
    method => 'GET',
    description => 'Returns a list of all matchers',
    protected => 1,
    permissions => {
	description => "Only lists entries where you have 'Mapping.Modify', 'Mapping.Use' or"
	    . " 'Mapping.Audit' permissions on '/mapping/notification/<name>'.",
	user => 'all',
    },
    parameters => {
	additionalProperties => 0,
	properties => {},
    },
    returns => {
	type => 'array',
	items => {
	    type => 'object',
	    properties => $matcher_properties,
	},
	links => [ { rel => 'child', href => '{name}' } ],
    },
    code => sub {
	my $config = PVE::Notify::read_config();
	my $rpcenv = PVE::RPCEnvironment::get();

	my $entities = eval {
	    $config->get_matchers();
	};
	raise_api_error($@) if $@;

	return filter_entities_by_privs($rpcenv, $entities);
    }
});

__PACKAGE__->register_method ({
    name => 'get_matcher',
    path => 'matchers/{name}',
    method => 'GET',
    description => 'Return a specific matcher',
    protected => 1,
    permissions => {
	check => ['or',
	    ['perm', '/mapping/notification/{name}', ['Mapping.Modify']],
	    ['perm', '/mapping/notification/{name}', ['Mapping.Audit']],
	],
    },
    parameters => {
	additionalProperties => 0,
	properties => {
	    name => {
		type => 'string',
		format => 'pve-configid',
	    },
	}
    },
    returns => {
	type => 'object',
	properties => {
	    %$matcher_properties,
	    digest => get_standard_option('pve-config-digest'),
	},
    },
    code => sub {
	my ($param) = @_;
	my $name = extract_param($param, 'name');

	my $config = PVE::Notify::read_config();

	my $matcher = eval {
	    $config->get_matcher($name)
	};

	raise_api_error($@) if $@;
	$matcher->{digest} = $config->digest();

	return $matcher;
    }
});

__PACKAGE__->register_method ({
    name => 'create_matcher',
    path => 'matchers',
    protected => 1,
    method => 'POST',
    description => 'Create a new matcher',
    protected => 1,
    permissions => {
	check => ['perm', '/mapping/notification', ['Mapping.Modify']],
    },
    parameters => {
	additionalProperties => 0,
	properties => $matcher_properties,
    },
    returns => { type => 'null' },
    code => sub {
	my ($param) = @_;

	my $name = extract_param($param, 'name');
	my $match_severity = extract_param($param, 'match-severity');
	my $match_field = extract_param($param, 'match-field');
	my $match_calendar = extract_param($param, 'match-calendar');
	my $target = extract_param($param, 'target');
	my $mode = extract_param($param, 'mode');
	my $invert_match = extract_param($param, 'invert-match');
	my $comment = extract_param($param, 'comment');

	eval {
	    PVE::Notify::lock_config(sub {
		my $config = PVE::Notify::read_config();

		$config->add_matcher(
		    $name,
		    $target,
		    $match_severity,
		    $match_field,
		    $match_calendar,
		    $mode,
		    $invert_match,
		    $comment,
		);

		PVE::Notify::write_config($config);
	    });
	};

	raise_api_error($@) if $@;
	return;
    }
});

__PACKAGE__->register_method ({
    name => 'update_matcher',
    path => 'matchers/{name}',
    protected => 1,
    method => 'PUT',
    description => 'Update existing matcher',
    permissions => {
	check => ['perm', '/mapping/notification/{name}', ['Mapping.Modify']],
    },
    parameters => {
	additionalProperties => 0,
	properties => {
	    %{ make_properties_optional($matcher_properties) },
	    delete => {
		type => 'array',
		items => {
		    type => 'string',
		    format => 'pve-configid',
		},
		optional => 1,
		description => 'A list of settings you want to delete.',
	    },
	    digest => get_standard_option('pve-config-digest'),
	},
    },
    returns => { type => 'null' },
    code => sub {
	my ($param) = @_;

	my $name = extract_param($param, 'name');
	my $match_severity = extract_param($param, 'match-severity');
	my $match_field = extract_param($param, 'match-field');
	my $match_calendar = extract_param($param, 'match-calendar');
	my $target = extract_param($param, 'target');
	my $mode = extract_param($param, 'mode');
	my $invert_match = extract_param($param, 'invert-match');
	my $comment = extract_param($param, 'comment');
	my $digest = extract_param($param, 'digest');
	my $delete = extract_param($param, 'delete');

	eval {
	    PVE::Notify::lock_config(sub {
		my $config = PVE::Notify::read_config();

		$config->update_matcher(
		    $name,
		    $target,
		    $match_severity,
		    $match_field,
		    $match_calendar,
		    $mode,
		    $invert_match,
		    $comment,
		    $delete,
		    $digest,
		);

		PVE::Notify::write_config($config);
	    });
	};

	raise_api_error($@) if $@;
	return;
    }
});

__PACKAGE__->register_method ({
    name => 'delete_matcher',
    protected => 1,
    path => 'matchers/{name}',
    method => 'DELETE',
    description => 'Remove matcher',
    permissions => {
	check => ['perm', '/mapping/notification/{name}', ['Mapping.Modify']],
    },
    parameters => {
	additionalProperties => 0,
	properties => {
	    name => {
		type => 'string',
		format => 'pve-configid',
	    },
	}
    },
    returns => { type => 'null' },
    code => sub {
	my ($param) = @_;
	my $name = extract_param($param, 'name');

	eval {
	    PVE::Notify::lock_config(sub {
		my $config = PVE::Notify::read_config();
		$config->delete_matcher($name);
		PVE::Notify::write_config($config);
	    });
	};

	raise_api_error($@) if $@;
	return;
    }
});

1;
