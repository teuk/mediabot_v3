package Mediabot::PluginManager;

use strict;
use warnings;
use utf8;

# ---------------------------------------------------------------------------
# Mediabot::PluginManager
# ---------------------------------------------------------------------------
# mb169-B1: minimal plugin manager foundation.
#
# This module deliberately loads no plugin by default. It gives Mediabot a
# central place to register trusted in-process Perl plugins later, and a clear
# boundary before we add any external Perl/Python/Tcl ScriptRunner support.
# ---------------------------------------------------------------------------

sub new {
    my ($class, %args) = @_;

    return bless {
        bot        => $args{bot},
        plugin_dir => $args{plugin_dir},
        plugins    => {}, # canonical name -> entry
        order      => [],
    }, $class;
}

sub bot {
    my ($self) = @_;
    return $self->{bot};
}

sub plugin_dir {
    my ($self) = @_;
    return $self->{plugin_dir};
}

sub _name {
    my ($name) = @_;
    return undef unless defined $name;
    $name =~ s/^\s+|\s+$//g;
    return undef unless length $name;
    return lc $name;
}

sub register_plugin {
    my ($self, %args) = @_;

    my $name = _name($args{name});
    die "PluginManager: missing plugin name\n" unless defined $name;

    if (exists $self->{plugins}{$name} && !$args{replace}) {
        die "PluginManager: plugin '$name' already registered\n";
    }

    my $entry = {
        name        => $name,
        module      => $args{module},
        object      => $args{object},
        version     => $args{version},
        description => $args{description},
        enabled     => exists $args{enabled} ? ($args{enabled} ? 1 : 0) : 1,
        metadata    => (ref($args{metadata}) eq 'HASH') ? { %{ $args{metadata} } } : {},
    };

    if (!exists $self->{plugins}{$name}) {
        push @{ $self->{order} }, $name;
    }

    $self->{plugins}{$name} = $entry;
    return $entry;
}

sub register {
    my ($self, %args) = @_;
    return $self->register_plugin(%args);
}

sub unregister_plugin {
    my ($self, $name) = @_;

    my $key = _name($name);
    return 0 unless defined $key;
    return 0 unless exists $self->{plugins}{$key};

    delete $self->{plugins}{$key};
    @{ $self->{order} } = grep { $_ ne $key } @{ $self->{order} };

    return 1;
}

sub plugin {
    my ($self, $name) = @_;

    my $key = _name($name);
    return undef unless defined $key;

    return $self->{plugins}{$key};
}

sub object_for {
    my ($self, $name) = @_;

    my $entry = $self->plugin($name);
    return undef unless $entry;

    return $entry->{object};
}

sub is_registered {
    my ($self, $name) = @_;
    return defined $self->plugin($name) ? 1 : 0;
}

sub enable {
    my ($self, $name) = @_;

    my $entry = $self->plugin($name) or return 0;
    $entry->{enabled} = 1;

    return 1;
}

sub disable {
    my ($self, $name) = @_;

    my $entry = $self->plugin($name) or return 0;
    $entry->{enabled} = 0;

    return 1;
}

sub is_enabled {
    my ($self, $name) = @_;

    my $entry = $self->plugin($name) or return 0;
    return $entry->{enabled} ? 1 : 0;
}

sub list {
    my ($self, %opts) = @_;

    my @names = @{ $self->{order} };
    my @entries;

    for my $name (@names) {
        my $entry = $self->{plugins}{$name} or next;
        next if exists $opts{enabled} && (($entry->{enabled} ? 1 : 0) != ($opts{enabled} ? 1 : 0));
        push @entries, $entry;
    }

    return @entries;
}

sub names {
    my ($self, %opts) = @_;
    return map { $_->{name} } $self->list(%opts);
}

sub count {
    my ($self, %opts) = @_;
    my @entries = $self->list(%opts);
    return scalar @entries;
}

sub _valid_module_name {
    my ($module) = @_;

    return 0 unless defined $module && length $module;
    return $module =~ /\A[A-Za-z_][A-Za-z0-9_]*(?:::[A-Za-z_][A-Za-z0-9_]*)*\z/ ? 1 : 0;
}

sub _split_plugin_list {
    my ($value) = @_;

    return () unless defined $value;

    my @items = split /[,\s]+/, $value;
    my @plugins;

    for my $item (@items) {
        next unless defined $item;
        $item =~ s/^\s+|\s+$//g;
        next unless length $item;
        push @plugins, $item;
    }

    return @plugins;
}

sub _conf_get_first {
    my ($conf, @keys) = @_;

    return undef unless $conf;

    for my $key (@keys) {
        next unless defined $key && length $key;

        my $value;
        my $ok = eval {
            if (ref($conf) eq 'HASH') {
                $value = $conf->{$key};
            }
            elsif ($conf->can('get')) {
                $value = $conf->get($key);
            }
            1;
        };

        next unless $ok;
        return $value if defined $value && length "$value";
    }

    return undef;
}

sub configured_modules_from_conf {
    my ($self, $conf, %opts) = @_;

    # mb170-B1: accept several key spellings to stay compatible with
    # Config::Simple section.key style and older flat-style configs.
    my $raw = _conf_get_first(
        $conf,
        $opts{key} || (),
        'plugins.ENABLED',
        'plugins.enabled',
        'plugins.PLUGINS',
        'plugins.plugins',
        'PLUGINS_ENABLED',
        'PLUGIN_ENABLED',
        'PLUGINS',
    );

    my @modules = _split_plugin_list($raw);
    my @valid;
    my @invalid;

    for my $module (@modules) {
        if (_valid_module_name($module)) {
            push @valid, $module;
        }
        else {
            push @invalid, $module;
        }
    }

    return wantarray ? (@valid) : {
        modules => \@valid,
        invalid => \@invalid,
        raw     => $raw,
    };
}

sub load_configured_plugins {
    my ($self, $conf, %opts) = @_;

    # This method is intentionally explicit. Mediabot does not call it from the
    # constructor in mb170, so no plugin is loaded unless the core later decides
    # to opt in at a controlled boot point.
    my $parsed = $self->configured_modules_from_conf($conf, %opts);
    my @modules = @{ $parsed->{modules} || [] };
    my @loaded;
    my @errors;

    for my $module (@modules) {
        my $entry = eval {
            $self->load_perl_module($module, replace => $opts{replace});
        };

        if ($entry) {
            push @loaded, $entry;
        }
        else {
            my $err = $@ || 'unknown plugin load error';
            $err =~ s/\s+/ /g;
            push @errors, {
                module => $module,
                error  => $err,
            };
        }
    }

    return {
        loaded  => \@loaded,
        errors  => \@errors,
        invalid => $parsed->{invalid} || [],
        raw     => $parsed->{raw},
    };
}


sub load_perl_module {
    my ($self, $module, %opts) = @_;

    die "PluginManager: missing module name\n"
        unless defined $module && length $module;

    # Only allow normal Perl module names here. No paths, no arbitrary eval text.
    die "PluginManager: invalid module name '$module'\n"
        unless _valid_module_name($module);

    my $file = $module;
    $file =~ s{::}{/}g;
    $file .= '.pm';

    my $ok = eval {
        require $file;
        1;
    };

    die "PluginManager: failed to load $module: $@\n" unless $ok;

    my $name = $opts{name} || $module;

    my $object;
    if ($module->can('register')) {
        $object = $module->register($self->{bot}, manager => $self);
    }

    return $self->register_plugin(
        name        => $name,
        module      => $module,
        object      => $object,
        version     => $module->can('VERSION') ? $module->VERSION : undef,
        description => $opts{description},
        enabled     => exists $opts{enabled} ? $opts{enabled} : 1,
        metadata    => $opts{metadata},
        replace     => $opts{replace},
    );
}

1;
