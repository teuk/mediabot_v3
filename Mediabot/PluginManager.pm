package Mediabot::PluginManager;

use strict;
use warnings;
use utf8;

use Scalar::Util qw(refaddr);

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

sub _same_plugin_object {
    my ($left, $right) = @_;

    # mb258-B1: plugin lifecycle identity must be reference identity, not
    # stringification. Plugin objects may overload stringification; two
    # different objects can stringify to the same value and must still be
    # treated as different instances for unregister/replace cleanup.
    return 0 unless ref($left) && ref($right);

    my $left_id  = eval { refaddr($left) };
    my $right_id = eval { refaddr($right) };

    return 0 unless defined $left_id && defined $right_id;
    return $left_id == $right_id ? 1 : 0;
}


sub _plugin_error_text {
    my ($err, $fallback) = @_;

    # mb279-B1: plugin lifecycle diagnostics are rendered to operators and
    # commit/preflight reports. Perl can die with HASH/ARRAY/blessed refs; do
    # not stringify those into HASH(...)/ARRAY(...) placeholders. Keep useful
    # scalar errors single-line and bounded, otherwise use a stable fallback.
    $fallback ||= 'plugin error';
    return $fallback unless defined $err;
    return $fallback if ref($err);

    my $text = "$err";
    $text =~ s/[\r\n\0]+/ /g;
    $text =~ s/\s+/ /g;
    $text =~ s/^\s+|\s+$//g;

    return $fallback unless length $text;
    return substr($text, 0, 240);
}

sub _name {
    my ($name) = @_;

    # mb276-B1: plugin names are plugin-manager identifiers, not arbitrary
    # Perl references.  Do not let ARRAY/HASH/blessed refs stringify into
    # pseudo plugin names such as ARRAY(0x...) or HASH(0x...).
    return undef unless defined $name;
    return undef if ref($name);

    $name =~ s/^\s+|\s+$//g;
    return undef unless length $name;
    return lc $name;
}

sub register_plugin {
    my ($self, %args) = @_;

    die "PluginManager: plugin name must be scalar\n" if ref($args{name});

    my $name = _name($args{name});
    die "PluginManager: missing plugin name\n" unless defined $name;

    if (exists $self->{plugins}{$name} && !$args{replace}) {
        die "PluginManager: plugin '$name' already registered\n";
    }

    # mb247-B1: direct register_plugin(..., replace => 1) must also clean the
    # replaced plugin object's runtime hooks.  load_perl_module() already has
    # a deferred cleanup path because it must avoid destructive pre-cleanup if
    # require/register fails; direct register_plugin() has no such load phase,
    # so the old object can be unregistered immediately after the replacement
    # entry is installed.
    my $previous_entry = ($args{replace} && exists $self->{plugins}{$name})
        ? $self->{plugins}{$name}
        : undef;

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

    # mb248-B1: a same-object replace is a metadata refresh, not an unload.
    # If register_plugin(..., replace => 1) is called with the exact same
    # plugin object that is already registered, calling unregister() here would
    # tear down the still-current object's EventBus listener. Only clean up when
    # the replacement object is different from the previous one.
    my $previous_object = $previous_entry ? $previous_entry->{object} : undef;
    my $replacement_object = $entry->{object};
    my $replacement_is_same_object = _same_plugin_object($previous_object, $replacement_object);

    if ($previous_entry
        && !$args{defer_unregister_cleanup}
        && ref($previous_object)
        && !$replacement_is_same_object
        && eval { $previous_object->can('unregister') }) {
        my $ok = eval { $previous_object->unregister(manager => $self); 1 };
        if (!$ok) {
            $entry->{metadata}{replace_cleanup_error} = _plugin_error_text($@, 'plugin unregister failed');
        }
    }

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

    my $entry = $self->{plugins}{$key};

    # mb244-B1: explicit plugin unregister must also give the plugin object a
    # chance to remove runtime hooks such as EventBus listeners.  MB242 already
    # cleaned the replace=>1 path; this closes the direct unregister_plugin()
    # path so a disabled/unloaded plugin cannot leave ghost observers behind.
    if ($entry && ref($entry->{object}) && eval { $entry->{object}->can('unregister') }) {
        my $ok = eval { $entry->{object}->unregister(manager => $self); 1 };
        if (!$ok) {
            $entry->{metadata}{unregister_error} = _plugin_error_text($@, 'plugin unregister failed');
        }
    }

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

    # mb276-B2: module names are Perl module identifiers and must be scalars.
    # Reject references before regex validation so diagnostics do not contain
    # stringified ARRAY(...)/HASH(...) pseudo module names.
    return 0 unless defined $module;
    return 0 if ref($module);
    return 0 unless length $module;
    return $module =~ /\A[A-Za-z_][A-Za-z0-9_]*(?:::[A-Za-z_][A-Za-z0-9_]*)*\z/ ? 1 : 0;
}

sub _split_plugin_list {
    my ($value) = @_;

    return () unless defined $value;

    # mb193-B2: Config::Simple may return ARRAY refs for comma-separated
    # configuration values. Flatten nested ARRAY refs before applying the
    # historical comma/whitespace split logic.
    my @queue = ($value);
    my @raw;

    while (@queue) {
        my $entry = shift @queue;
        next unless defined $entry;

        if (ref($entry) eq 'ARRAY') {
            unshift @queue, @$entry;
            next;
        }

        # mb266-B1: plugin list configuration is a scalar/list contract.  A
        # HASH/blessed ref must not be stringified into HASH(0x...) and reported
        # as an invalid plugin module, nor should it be considered meaningful by
        # fallback selection.  Keep ARRAY support, skip every other reference.
        next if ref($entry);

        push @raw, $entry;
    }

    my @items;
    for my $entry (@raw) {
        push @items, split /[,\s]+/, "$entry";
    }

    @items = map {
        my $v = $_;
        $v =~ s/^\s+|\s+$//g;
        $v;
    } @items;

    return grep { length $_ } @items;
}


sub _plugin_conf_has_meaningful_scalar {
    my ($value) = @_;

    # mb266-B2: fallback-key selection must use the same scalar/list contract as
    # _split_plugin_list().  Empty ARRAY refs and HASH/blessed refs from an early
    # config spelling must not mask a later legacy/alias key that contains the
    # real plugin list.
    return scalar(_split_plugin_list($value)) ? 1 : 0;
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
        return $value if _plugin_conf_has_meaningful_scalar($value);
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
            my $err = _plugin_error_text($@, 'unknown plugin load error');
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

    die "PluginManager: module name must be scalar\n" if ref($module);

    die "PluginManager: missing module name\n"
        unless defined $module && length $module;

    # Only allow normal Perl module names here. No paths, no arbitrary eval text.
    die "PluginManager: invalid module name '$module'\n"
        unless _valid_module_name($module);

    my $name = $opts{name} || $module;
    die "PluginManager: plugin name must be scalar\n" if ref($name);

    my $key  = _name($name);
    die "PluginManager: missing plugin name\n" unless defined $key;

    # mb233-B1: reject duplicate plugin loads before require/register. A plugin
    # module may perform registration side effects from its register() method,
    # for example adding EventBus listeners. The old flow called register()
    # first and only rejected the duplicate in register_plugin(), which meant a
    # failed duplicate load could still leave runtime side effects behind.
    die "PluginManager: plugin '$key' already registered\n"
        if exists $self->{plugins}{$key} && !$opts{replace};

    # mb242-B3: when replacing a plugin, remember the old object so it can
    # unregister its own runtime hooks after the replacement has registered.
    # This keeps reloads from accumulating EventBus listeners while avoiding a
    # destructive pre-cleanup if the new module fails to load/register.
    my $previous_entry = ($opts{replace} && exists $self->{plugins}{$key})
        ? $self->{plugins}{$key}
        : undef;

    my $file = $module;
    $file =~ s{::}{/}g;
    $file .= '.pm';

    my $ok = eval {
        require $file;
        1;
    };

    die "PluginManager: failed to load $module: " . _plugin_error_text($@, 'require failed') . "\n" unless $ok;

    my $object;
    if ($module->can('register')) {
        # mb245-B2: tell the plugin the manager-facing name used for this
        # registration.  Plugins such as ScriptDryRun can then honour the
        # PluginManager enabled/disabled flag even when loaded under a custom
        # explicit name.  This does not change the historical default module
        # name registration path.
        # mb279-B2: plugin register() may die with a HASH/ARRAY/blessed ref.
        # Convert that boundary failure into a scalar diagnostic before it can
        # be stringified by load_configured_plugins() or direct callers.
        my $registered = eval {
            $object = $module->register($self->{bot}, manager => $self, name => $name);
            1;
        };
        die "PluginManager: failed to register $module: " . _plugin_error_text($@, 'plugin register failed') . "
"
            unless $registered;
    }

    my $entry = $self->register_plugin(
        name        => $name,
        module      => $module,
        object      => $object,
        version     => $module->can('VERSION') ? $module->VERSION : undef,
        description => $opts{description},
        enabled     => exists $opts{enabled} ? $opts{enabled} : 1,
        metadata    => $opts{metadata},
        replace     => $opts{replace},
        defer_unregister_cleanup => 1,
    );

    # mb249-B1: load_perl_module(..., replace => 1) must mirror the
    # same-object guard already present in direct register_plugin(). Some
    # plugins may return a singleton/current object from register(); in that
    # case the replacement is only a metadata refresh and calling unregister()
    # on the previous object would tear down the still-current plugin hooks.
    my $previous_object = $previous_entry ? $previous_entry->{object} : undef;
    my $replacement_object = $entry->{object};
    my $replacement_is_same_object = _same_plugin_object($previous_object, $replacement_object);

    if ($previous_entry
        && ref($previous_object)
        && !$replacement_is_same_object
        && eval { $previous_object->can('unregister') }) {
        my $ok = eval { $previous_object->unregister(manager => $self); 1 };
        if (!$ok) {
            $entry->{metadata}{replace_cleanup_error} = _plugin_error_text($@, 'plugin unregister failed');
        }
    }

    return $entry;
}

1;
