package Mediabot::Plugin::RuntimeV3;

use strict;
use warnings;
use utf8;

use Cwd qw(realpath);
use File::Spec;
use JSON::PP ();
use Scalar::Util qw(blessed);

use Mediabot::Plugin::ManifestV3;
use Mediabot::PluginContext;

sub new {
    my ($class, %args) = @_;

    die "Plugin API v3 runtime: manager is required\n"
        unless $args{manager};
    my $plugin_dir = $args{plugin_dir};
    $plugin_dir = 'plugins' unless defined($plugin_dir) && !ref($plugin_dir)
        && length($plugin_dir);

    return bless {
        manager    => $args{manager},
        plugin_dir => $plugin_dir,
    }, $class;
}

sub plugin_dir { $_[0]->{plugin_dir} }

sub _root {
    my ($self) = @_;
    my $root = realpath($self->{plugin_dir});
    die "Plugin API v3 runtime: plugin directory does not exist\n"
        unless defined($root) && -d $root && !-l $self->{plugin_dir};
    return $root;
}

sub _package {
    my ($self, $name) = @_;
    die "Plugin API v3 runtime: package name must be a lowercase slug\n"
        unless defined($name) && !ref($name)
            && $name =~ /\A[a-z0-9][a-z0-9-]{0,47}\z/;

    my $root = $self->_root;
    my $dir = File::Spec->catdir($root, $name);
    die "Plugin API v3 runtime: package '$name' is not a regular directory\n"
        unless -d $dir && !-l $dir;
    my $real_dir = realpath($dir);
    die "Plugin API v3 runtime: package '$name' escapes the plugin directory\n"
        unless defined($real_dir)
            && ($real_dir eq $root || index($real_dir, "$root/") == 0);

    my $manifest_path = File::Spec->catfile($real_dir, 'plugin.json');
    my $manifest = Mediabot::Plugin::ManifestV3->load_file(
        $manifest_path,
        expected_name => $name,
    );
    return ($real_dir, $manifest);
}

sub discover_packages {
    my ($self) = @_;
    my $root = $self->_root;

    opendir my $dh, $root
        or die "Plugin API v3 runtime: cannot open plugin directory: $!\n";
    my @names = sort grep {
        !/^\./ && /\A[a-z0-9][a-z0-9-]{0,47}\z/
            && -d File::Spec->catdir($root, $_)
            && !-l File::Spec->catdir($root, $_)
            && -f File::Spec->catfile($root, $_, 'plugin.json')
            && !-l File::Spec->catfile($root, $_, 'plugin.json')
    } readdir $dh;
    closedir $dh;

    my @packages;
    for my $name (@names) {
        my ($dir, $manifest) = $self->_package($name);
        push @packages, {
            name         => $name,
            version      => $manifest->{version},
            description  => $manifest->{description},
            activation   => $manifest->{activation}{default},
            capabilities => [ @{ $manifest->{capabilities} } ],
            package_dir  => $dir,
            manifest     => $manifest,
        };
    }
    return wantarray ? @packages : \@packages;
}

sub load_package {
    my ($self, $name, %opts) = @_;

    my $manager = $self->{manager};
    die "Plugin API v3 runtime: package '$name' is already registered\n"
        if $manager->is_registered($name);

    my ($dir, $manifest) = $self->_package($name);
    my %requested = map { $_ => 1 } @{ $manifest->{capabilities} };
    my $grants = ref($opts{grants}) eq 'ARRAY' ? $opts{grants} : [];
    my %seen_grant;
    for my $grant (@$grants) {
        die "Plugin API v3 runtime: grants must be scalar capability names\n"
            unless defined($grant) && !ref($grant);
        die "Plugin API v3 runtime: capability '$grant' was not requested by '$name'\n"
            unless $requested{$grant};
        die "Plugin API v3 runtime: capability '$grant' was granted twice\n"
            if $seen_grant{$grant}++;
    }

    require Mediabot::Plugin::ConfigSchemaV3;
    require Mediabot::Plugin::ChannelPolicyV3;
    my $config_schema = Mediabot::Plugin::ConfigSchemaV3->new(
        schema => ($manifest->{config_schema} || {}),
    );
    my $channel_policy = Mediabot::Plugin::ChannelPolicyV3->new(
        schema   => $config_schema,
        policies => (exists($opts{channel_policies})
            ? $opts{channel_policies} : {}),
    );

    my $entrypoint = File::Spec->catfile(
        $dir,
        split('/', $manifest->{runtime}{entrypoint}),
    );
    die "Plugin API v3 runtime: entrypoint must be a regular non-symlink file\n"
        unless -f $entrypoint && !-l $entrypoint;
    my $real_entrypoint = realpath($entrypoint);
    die "Plugin API v3 runtime: entrypoint escapes package '$name'\n"
        unless defined($real_entrypoint) && index($real_entrypoint, "$dir/") == 0;

    my $loaded = eval { require $real_entrypoint; 1 };
    die "Plugin API v3 runtime: cannot load entrypoint for '$name'\n"
        unless $loaded;
    my $class = $manifest->{runtime}{class};
    die "Plugin API v3 runtime: class '$class' has no constructor\n"
        unless $class->can('new');

    my $context = Mediabot::PluginContext->new(
        plugin    => $name,
        requested => $manifest->{capabilities},
        granted   => $grants,
        http_fetch_sink => sub {
            return $manager->_v3_http_fetch($name, @_);
        },
        storage_snapshot_sink => sub {
            return $manager->_v3_storage_snapshot($name, @_);
        },
        storage_commit_sink => sub {
            return $manager->_v3_storage_commit($name, @_);
        },
        quotes_read_sink => sub {
            return $manager->_v3_quotes_read($name, @_);
        },
        quotes_write_sink => sub {
            return $manager->_v3_quotes_write($name, @_);
        },
        factoids_read_sink => sub {
            return $manager->_v3_factoids_read($name, @_);
        },
    );
    # The plugin receives a detached manifest snapshot. It cannot rewrite the
    # already validated core-owned contract between validation and mounting.
    my $plugin_manifest = JSON::PP->new->decode(
        JSON::PP->new->canonical->encode($manifest));
    my $object = eval {
        $class->new(context => $context, manifest => $plugin_manifest)
    };
    die "Plugin API v3 runtime: constructor failed for '$name'\n"
        unless blessed($object);

    for my $command (sort keys %{ $manifest->{commands} }) {
        my $method = $manifest->{commands}{$command}{handler};
        die "Plugin API v3 runtime: command '$command' has no handler '$method'\n"
            unless $object->can($method);
    }
    require Mediabot::Plugin::EventCatalogV3;
    for my $event (@{ $manifest->{events} }) {
        Mediabot::Plugin::EventCatalogV3->assert_supported(
            $event->{name}, $event->{version});
        my $method = $event->{handler};
        die "Plugin API v3 runtime: event '$event->{name}' has no handler '$method'\n"
            unless $object->can($method);
    }
    for my $job (sort keys %{ $manifest->{jobs} || {} }) {
        my $method = $manifest->{jobs}{$job}{handler};
        die "Plugin API v3 runtime: job '$job' has no handler '$method'\n"
            unless $object->can($method);
    }

    my $entry = $manager->register_plugin(
        name        => $name,
        module      => $class,
        object      => $object,
        version     => $manifest->{version},
        description => $manifest->{description},
        enabled     => 0,
        manifest    => $manifest,
        metadata    => {
            api                    => 3,
            kind                   => 'package-v3',
            package_dir            => $dir,
            requested_capabilities => [ sort keys %requested ],
            granted_capabilities   => [ sort keys %seen_grant ],
            effective_capabilities => [ $context->effective_capabilities ],
            plugin_context         => $context,
            config_schema          => $config_schema,
            channel_policy         => $channel_policy,
        },
    );

    my $mounted = eval {
        $manager->_mount_v3_commands($name, $entry);
        $manager->_mount_v3_events($name, $entry);
        $manager->_mount_v3_jobs($name, $entry);
        1;
    };
    unless ($mounted) {
        my $error = $@ || 'runtime resource mounting failed';
        $manager->unregister_plugin($name);
        die $error;
    }

    if ($opts{enable}) {
        my $enabled = eval { $manager->enable($name); 1 };
        unless ($enabled) {
            my $error = $@ || 'activation failed';
            $manager->unregister_plugin($name);
            die $error;
        }
    }
    return $entry;
}

1;
