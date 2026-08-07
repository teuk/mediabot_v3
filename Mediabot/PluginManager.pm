package Mediabot::PluginManager;

use strict;
use warnings;
use File::Spec;
use JSON::PP ();

# mb593-B1: evenements routables vers les scripts sidecar — la liste blanche
# exacte de ce que le bot emet aujourd'hui (public_command_observed au
# dispatch public, channel_<type>_observed via observe_channel_event pour
# join/part/topic/kick). Etendre cette table quand le bot emettra plus.
our %ROUTABLE_SCRIPT_EVENTS = map { $_ => 1 } qw(
    public_command_observed
    channel_join_observed
    channel_part_observed
    channel_topic_observed
    channel_kick_observed
    channel_nick_observed
    channel_quit_observed
    plugin_cron_observed
);

use utf8;

use Scalar::Util qw(refaddr blessed reftype);

# ---------------------------------------------------------------------------
# Mediabot::PluginManager
# ---------------------------------------------------------------------------
# Active manager for trusted in-process Perl plugins and declarative external
# script plugins.
#
# It owns registration, replacement, unregister cleanup and configuration-driven
# loading behind Mediabot's explicit plugins.AUTOLOAD boot gate. External
# Perl/Python/Tcl scripts stay out of process: ScriptDryRun and plugin-v2 sidecars
# delegate execution to ScriptRunner across the mediabot-script-v1 boundary.
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
        # mb586-B1: manifest v2 valide (undef pour un plugin v1 legacy).
        manifest    => (ref($args{manifest}) eq 'HASH') ? $args{manifest} : undef,
        # mb600-B1: config effective d'un plugin script (defaults sidecar +
        # surcharges conf), snapshotee au load.
        plugin_config => (ref($args{plugin_config}) eq 'HASH') ? $args{plugin_config} : undef,
    };
    $entry->{metadata}{api} ||= $entry->{manifest} ? 2 : 1;

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

    # mb587-B1: replace avec objet different = les commandes montees de
    # l'ancien objet tombent (le chemin de load remontera celles du nouveau).
    # Un same-object refresh les conserve (metadata refresh mb248).
    if ($previous_entry
        && !$replacement_is_same_object
        && !$args{defer_command_cleanup}) {
        $self->_unmount_entry_commands($previous_entry);
    }
    elsif ($previous_entry
        && $replacement_is_same_object
        && !$args{defer_command_cleanup}) {
        $entry->{mounted_commands} = $previous_entry->{mounted_commands};
    }

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

    # mb587-B1: demonter les commandes du registry AVANT le teardown objet —
    # une commande fantome qui dispatche vers un plugin retire serait le
    # jumeau exact des listeners fantomes mb233.
    $self->_unmount_entry_commands($entry);
    # mb593-B1: et desabonner les events routes des scripts, au meme point.
    $self->_unsubscribe_entry_events($entry);

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

    # Explicit configuration-loading entry point. The constructor never autoloads;
    # Mediabot calls this method only after the plugins.AUTOLOAD boot gate passes.
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


# ---------------------------------------------------------------------------
# mb586-B1: contrat plugin v2 — le MANIFEST.
#
# Un plugin v2 expose une sub manifest retournant un HASH declaratif :
#   { api => 2, name => 'demo', version => '0.001',
#     description => '...',
#     commands => { hello => { help => 'Say hello.', level => 0 } },
#     events   => [ 'public_command_observed' ] }
#
# La validation est FAIL-CLOSED et se joue AVANT $module->register() : un
# manifest invalide ne produit AUCUN effet de bord (meme discipline que le
# refus de doublon mb233 place avant require/register). Un module SANS
# manifest reste un plugin v1 legacy, accepte tel quel (api=1) — zero
# regression sur l'existant. Ce round pose le contrat et ses gardes ; le
# montage automatique des commandes declarees dans le CommandRegistry est
# l'increment suivant de l'arc v2.
# ---------------------------------------------------------------------------
sub _validate_manifest {
    my ($self, $module, $key, $m, %vopt) = @_;

    return 'manifest must return a HASH reference' unless ref($m) eq 'HASH';
    return 'manifest api must be the integer 2'
        unless defined $m->{api} && !ref($m->{api}) && $m->{api} =~ /\A2\z/;

    my $name = $m->{name};
    return 'manifest name is required'
        unless defined $name && !ref($name) && length $name;
    return "manifest name '$name' is not a valid slug"
        unless $name =~ /\A[a-z0-9][a-z0-9_-]{0,31}\z/;
    # le manifest ne peut pas usurper une autre identite : son name doit
    # correspondre au nom d'enregistrement, complet ou dernier segment.
    my $short = lc($module); $short =~ s/.*:://;
    # mb590-B1: pour un script, l'identite courte = basename sans extension
    # (plugins/hello.py -> hello) ; pour un module Perl, dernier segment.
    (my $script_short = $short) =~ s{.*/}{}; $script_short =~ s/\.[a-z0-9]+\z//;
    return "manifest name '$name' does not match registration '$key'"
        unless lc($name) eq $key || lc($name) eq $short
            || lc($name) eq $script_short;

    return 'manifest version is required (digits and dots, e.g. 0.001)'
        unless defined $m->{version} && !ref($m->{version})
            && $m->{version} =~ /\A[0-9]+(?:\.[0-9]+){0,3}\z/;

    if (defined $m->{description}) {
        return 'manifest description must be a short scalar'
            if ref($m->{description}) || length($m->{description}) > 200;
    }

    if (defined $m->{commands}) {
        return 'manifest commands must be a HASH' unless ref($m->{commands}) eq 'HASH';
        my $registry = $self->{bot} && eval { $self->{bot}->can('registry') }
            ? eval { $self->{bot}->registry } : undef;
        for my $cmd (sort keys %{ $m->{commands} }) {
            return "manifest command '$cmd' is not a valid command name"
                unless $cmd =~ /\A[a-z][a-z0-9_]{0,23}\z/;
            my $spec = $m->{commands}{$cmd};
            return "manifest command '$cmd' spec must be a HASH"
                unless ref($spec) eq 'HASH';
            return "manifest command '$cmd' needs a short help string"
                unless defined $spec->{help} && !ref($spec->{help})
                    && length($spec->{help}) && length($spec->{help}) <= 200;
            # mb589-B1: le pont d'autorisation est la — le contrat level
            # devient auto-documente : 0 = commande publique, sinon une
            # DESCRIPTION de la table USER_LEVEL de l'instance ('Owner',
            # 'Master', 'Administrator', 'User'...), verifiee au dispatch
            # via checkUserLevel (semantique maison : plus petit = plus
            # fort). Les entiers >0 du contrat mb586 n'ont JAMAIS ete
            # montables (refus mb587) : les refuser avec un message de
            # migration ne casse aucun plugin existant.
            return "manifest command '$cmd' level must be 0 (public) or a"
                 . " USER_LEVEL description string such as 'Master'"
                unless defined $spec->{level} && !ref($spec->{level});
            if ($spec->{level} =~ /\A[0-9]+\z/) {
                return "manifest command '$cmd' has numeric level"
                     . " $spec->{level}: since mb589 declare 0 (public) or a"
                     . " USER_LEVEL description string such as 'Master'"
                    if $spec->{level} > 0;
            }
            else {
                return "manifest command '$cmd' level '$spec->{level}' is not"
                     . " a valid USER_LEVEL description"
                    unless $spec->{level} =~ /\A[A-Za-z][A-Za-z ]{1,31}\z/;
            }
            # collision fail-closed : ni le registry du bot... — SAUF si la
            # commande enregistree appartient deja a CE plugin (mb588 : un
            # reload/replace de soi-meme n'est pas une collision ; l'entry
            # registry porte plugin=>$key depuis le montage mb587).
            if ($registry && eval { $registry->can('command_for') }) {
                my $existing = eval { $registry->command_for($cmd) };
                if ($existing
                    && !(defined $existing->{plugin} && $existing->{plugin} eq $key)) {
                    return "manifest command '$cmd' collides with an existing bot command";
                }
            }
            # ...ni un autre plugin deja enregistre.
            for my $other (@{ $self->{order} }) {
                next if $other eq $key;
                my $om = $self->{plugins}{$other}{manifest} or next;
                return "manifest command '$cmd' collides with plugin '$other'"
                    if ref($om->{commands}) eq 'HASH' && exists $om->{commands}{$cmd};
            }
            # fail-closed : un manifest qui declare une commande que le module
            # n'implemente pas (sub command_<nom>) est un manifest menteur.
            # mb590-B1: pour un SCRIPT hors process il n'y a pas de methode a
            # verifier — le mensonge ne se detecte qu'a l'execution (le run
            # echoue et le canal recoit un message sobre) ; skip documente.
            return "manifest command '$cmd' has no matching method command_$cmd"
                unless $vopt{skip_method_check} || $module->can("command_$cmd");
        }
    }

    # mb600-B1: bloc config du sidecar — les DEFAULTS de l'auteur. Memes
    # bornes que _normalize_config_map du runner (<=32 cles, cle style conf
    # MAJUSCULES, valeur scalaire <=512 octets) mais ici FAIL-CLOSED : un
    # bloc invalide refuse le manifest au lieu d'etre silencieusement
    # filtre — l'auteur apprend tout de suite.
    if (defined $m->{config}) {
        return 'manifest config must be a HASH of defaults'
            unless ref($m->{config}) eq 'HASH';
        my @ckeys = keys %{ $m->{config} };
        return 'manifest config allows at most 32 keys' if @ckeys > 32;
        for my $ckey (sort @ckeys) {
            return "manifest config key '$ckey' must match [A-Z][A-Z0-9_]{0,31}"
                unless $ckey =~ /\A[A-Z][A-Z0-9_]{0,31}\z/;
            my $cval = $m->{config}{$ckey};
            return "manifest config value for '$ckey' must be a scalar"
                if !defined $cval || ref($cval);
            return "manifest config value for '$ckey' exceeds 512 bytes"
                if length("$cval") > 512;
        }
    }

    if (defined $m->{events}) {
        return 'manifest events must be an ARRAY' unless ref($m->{events}) eq 'ARRAY';
        my %seen_event;
        for my $ev (@{ $m->{events} }) {
            return 'manifest events must be simple event names'
                unless defined $ev && !ref($ev) && $ev =~ /\A[a-z][a-z0-9_]*\z/;
            return "manifest event '$ev' is declared more than once"
                if $vopt{script_events_routable} && $seen_event{$ev}++;
            # mb593-B1: pour un SCRIPT, un event declare est un ROUTAGE reel
            # (le PluginManager s'abonne et lance le script) — seule la liste
            # blanche des evenements observables du bot est acceptee. Les
            # plugins in-process gardent leur liberte : ils s'abonnent
            # eux-memes dans register() et leur liste reste informationnelle.
            if ($vopt{script_events_routable}
                && !$ROUTABLE_SCRIPT_EVENTS{$ev}) {
                return "manifest event '$ev' is not routable to scripts"
                     . " (routable: " . join(', ', sort keys %ROUTABLE_SCRIPT_EVENTS) . ")";
            }
        }
    }

    return undef;
}

# mb587-B1: montage des commandes du manifest dans le CommandRegistry
# (source 'public'). Le handler enregistre est un wrapper qui verifie
# l'etat enabled du plugin a CHAQUE dispatch (un plugin disable se tait
# sans etre decharge), puis appelle $object->command_<nom>($ctx). La
# validation mb586/587 a deja garanti l'absence de collision et l'existence
# des methodes ; un echec residuel demonte ce qui vient d'etre monte
# (atomicite) et remonte l'erreur. L'entry memorise mounted_commands pour
# le demontage a l'unregister/replace.
# mb589-B1: verification d'autorisation d'une commande de plugin a niveau.
# Retourne (1) si le dispatch peut continuer, (0, raison courte) sinon.
# L'identite vient de get_user_from_message (le meme chemin que logBot et
# les commandes du bot) ; le niveau est compare par checkUserLevel — la
# methode du bot si elle existe (fixtures comprises), sinon le helper
# qualifie. Fail-closed de bout en bout : pas de message dans le ctx, user
# inconnu, non authentifie, ou niveau insuffisant = refus.
# mb601-B1: persistance KV par plugin — LE BOT ecrit, jamais le script.
# Fichier <DATA_DIR>/<key>.json (DATA_DIR = conf plugins.DATA_DIR, defaut
# 'plugin-data' relatif au CWD du bot, cree 0700 a la demande). $key est le
# nom d'enregistrement deja valide (slug) : aucune traversee possible.
# Ecriture ATOMIQUE (temp + rename), re-verification de la borne 16K a
# l'ecriture (defense en profondeur apres validate_action). Lecture a
# CHAQUE dispatch (l'etat doit etre frais, contrairement a la config
# snapshotee) ; un fichier invalide est journalise et ignore — jamais un
# die sur le chemin d'un dispatch. Deux dispatchs concurrents : dernier
# ecrit gagne, documente au cookbook.
sub _plugin_storage_log {
    my ($self, $level, $message) = @_;
    eval { $self->{bot}{logger}->log($level, $message) };
    return;
}

sub _plugin_data_dir {
    my ($self, %opts) = @_;

    my $dir = eval { $self->{bot}{conf}->get('plugins.DATA_DIR') };
    $dir = 'plugin-data' unless defined $dir && length $dir && !ref($dir);

    if (-e $dir && !-d $dir) {
        return (undef, "plugin data path '$dir' exists but is not a directory");
    }
    return ($dir, undef) if -d $dir;

    # mb602-B1: reads and .plugins info are genuinely read-only. The
    # directory is created only when a store action needs to write.
    return (undef, undef) unless $opts{create};

    mkdir $dir, 0700
        or return (undef, "cannot create plugin data dir '$dir': $!");
    return ($dir, undef);
}

sub _plugin_data_key {
    my ($name) = @_;

    my $key = _name($name);
    return undef unless defined $key;
    return undef unless $key =~ /\A[a-z0-9][a-z0-9_-]{0,31}\z/;
    return $key;
}

sub _plugin_data_path {
    my ($self, $name, %opts) = @_;

    my $key = _plugin_data_key($name);
    return (undef, 'invalid plugin storage name') unless defined $key;

    my ($dir, $err) = $self->_plugin_data_dir(create => ($opts{create} ? 1 : 0));
    return (undef, $err) unless defined $dir;
    return (File::Spec->catfile($dir, "$key.json"), undef);
}

sub _validate_plugin_data_object {
    my ($obj) = @_;

    my $loaded = eval { require Mediabot::ScriptActionRunner; 1 };
    return (0, 'storage validator unavailable') unless $loaded;
    return Mediabot::ScriptActionRunner::validate_storage_object($obj);
}

sub _mark_plugin_storage_invalid {
    my ($self, $key) = @_;
    return unless defined $key;
    _pm_metric($self->{bot}, 'mediabot_plugin_storage_read_invalid_total',
        { plugin => $key });
    # mb605-B1: a rejected file is not a current usable document. Reset the
    # gauge instead of leaving a stale pre-corruption value in Prometheus.
    _pm_gauge($self->{bot}, 'mediabot_plugin_storage_bytes', 0,
        { plugin => $key });
    return;
}

sub _read_plugin_data {
    my ($self, $name) = @_;

    my $key = _plugin_data_key($name);
    return undef unless defined $key;

    my ($path, $path_err) = $self->_plugin_data_path($key);
    if (defined $path_err && length $path_err) {
        $self->_plugin_storage_log(2,
            "PluginManager: cannot resolve storage for '$key': $path_err");
        return undef;
    }
    unless (defined $path && -f $path) {
        # mb605-B1: initialize/reconcile the gauge after restart and after a
        # missing file. A gauge called storage_bytes must describe NOW.
        _pm_gauge($self->{bot}, 'mediabot_plugin_storage_bytes', 0,
            { plugin => $key });
        return undef;
    }

    # A storage file is bot-owned state, never a redirect to another file.
    if (-l $path) {
        $self->_plugin_storage_log(1,
            "PluginManager: ignoring symlink storage file for '$key'");
        $self->_mark_plugin_storage_invalid($key);
        return undef;
    }

    open my $fh, '<:raw', $path or do {
        $self->_plugin_storage_log(2,
            "PluginManager: cannot read storage file for '$key': $!");
        return undef;
    };
    local $/;
    my $raw = <$fh>;
    close $fh;

    unless (defined $raw && length($raw) <= 16384 + 1024) {
        $self->_plugin_storage_log(2,
            "PluginManager: ignoring oversized storage file for '$key'");
        $self->_mark_plugin_storage_invalid($key);
        return undef;
    }

    my $obj = eval { JSON::PP->new->decode($raw) };
    my ($valid, $why) = _validate_plugin_data_object($obj);
    unless ($valid) {
        $self->_plugin_storage_log(2,
            "PluginManager: ignoring invalid storage file for '$key': "
            . _plugin_error_text($why, 'invalid storage object'));
        # mb604-B1: un fichier local abime n'est plus seulement une ligne de
        # journal — il devient une serie visible dans Grafana.
        $self->_mark_plugin_storage_invalid($key);
        return undef;
    }

    # mb605-B1: after a restart there has been no store call yet, but the
    # existing valid document is still current state and must seed the gauge.
    _pm_gauge($self->{bot}, 'mediabot_plugin_storage_bytes', length($raw),
        { plugin => $key });
    return $obj;
}

sub _store_plugin_data {
    my ($self, $name, $obj) = @_;

    my $key = _plugin_data_key($name);
    return (0, 'invalid plugin storage name') unless defined $key;

    # mb602-B1: repeat the COMPLETE storage contract at the disk boundary,
    # not only the 16 KiB check. This protects direct/internal sink callers
    # and keeps malformed local state out of future dispatch envelopes.
    my ($valid, $why) = _validate_plugin_data_object($obj);
    return (0, $why) unless $valid;

    my $json = eval { JSON::PP->new->canonical->encode($obj) };
    return (0, 'storage object is not JSON-serializable') unless defined $json;

    my ($path, $err) = $self->_plugin_data_path($key, create => 1);
    return (0, $err) unless defined $path;

    my $tmp = "$path.tmp.$$";
    open my $fh, '>:raw', $tmp or return (0, "cannot write '$tmp': $!");
    unless (chmod 0600, $tmp) {
        my $chmod_err = $!;
        close $fh;
        unlink $tmp;
        return (0, "cannot chmod '$tmp': $chmod_err");
    }

    unless (print {$fh} $json) {
        my $write_err = $!;
        close $fh;
        unlink $tmp;
        return (0, "cannot write '$tmp': $write_err");
    }
    close $fh or do { unlink $tmp; return (0, "cannot close '$tmp': $!") };
    rename $tmp, $path
        or do { unlink $tmp; return (0, "cannot rename into '$path': $!") };
    # mb604-B1: une ecriture reussie = un compteur et la TAILLE COURANTE du
    # document (gauge : la valeur remplace la precedente, comme le document).
    _pm_metric($self->{bot}, 'mediabot_plugin_store_total', { plugin => $key });
    _pm_gauge($self->{bot}, 'mediabot_plugin_storage_bytes',
        length($json), { plugin => $key });
    return (1, undef);
}

sub plugin_data_info {
    my ($self, $name) = @_;

    my $key = _plugin_data_key($name);
    return (undef, 'invalid plugin storage name') unless defined $key;

    my ($path, $err) = $self->_plugin_data_path($key);
    return (undef, $err) if defined $err && length $err;
    return (undef, undef) unless defined $path && -f $path && !-l $path;

    my $size = -s $path;
    return ({ path => $path, size => (defined $size ? $size : 0) }, undef);
}

sub clear_plugin_data {
    my ($self, $name) = @_;

    my $key = _plugin_data_key($name);
    return (0, 0, 'invalid plugin storage name') unless defined $key;

    my ($path, $err) = $self->_plugin_data_path($key);
    return (0, 0, $err) if defined $err && length $err;
    unless (defined $path && -f $path && !-l $path) {
        _pm_gauge($self->{bot}, 'mediabot_plugin_storage_bytes', 0,
            { plugin => $key });
        return (1, 0, undef);
    }

    if (unlink $path) {
        # mb605-B1: clear means zero bytes now, not the last value written.
        _pm_gauge($self->{bot}, 'mediabot_plugin_storage_bytes', 0,
            { plugin => $key });
        return (1, 1, undef);
    }
    return (0, 0, "cannot clear storage for '$key': $!");
}

# mb604-B1: un refus d'ecriture doit dire POURQUOI, en cardinalite bornee.
# Les refus naissent a deux endroits : au PLAN (bornes du contrat, avant
# toute application) et a l'APPLICATION (gate fermee, second store, panne
# du sink). On les ramene a un petit vocabulaire fixe — un label libre
# tire du message d'erreur ferait exploser les series Prometheus.
sub _store_rejection_reason {
    my ($text) = @_;
    $text = '' unless defined $text && !ref($text);
    return 'too_large'      if $text =~ /exceeds \d+ bytes/;
    return 'too_deep'       if $text =~ /deeper than/;
    return 'too_many_keys'  if $text =~ /more than \d+ keys|longer than \d+ items/;
    return 'key_too_long'   if $text =~ /key longer than/;
    return 'not_an_object'  if $text =~ /must be an object|unsupported reference|not JSON-serializable|not a plain scalar/;
    return 'duplicate'      if $text =~ /only one store action/;
    return 'no_sink'        if $text =~ /require allow_store/;
    return 'invalid_name'   if $text =~ /invalid plugin storage name/;
    return 'write_failed'   if $text =~ /cannot (?:write|close|rename|create|chmod)/;
    return 'other';
}

sub _pm_store_rejections {
    my ($bot, $key, $plan) = @_;
    return unless ref($plan) eq 'HASH';

    # mb605-B1: observability is never allowed to change dispatch semantics.
    # A legacy/custom action runner may return malformed diagnostic fields;
    # inspect only real arrays and keep the collector itself fail-safe.
    my $errors = ref($plan->{errors}) eq 'ARRAY' ? $plan->{errors} : [];
    for my $err (@$errors) {
        my $text = ref($err) eq 'HASH' ? ($err->{error} // '')
                 : !ref($err)          ? ($err // '')
                 :                       '';
        next unless length($text) && $text =~ /store action rejected/;
        _pm_metric($bot, 'mediabot_plugin_store_rejected_total',
            { plugin => $key, reason => _store_rejection_reason($text) });
    }

    my $apply_errors = ref($plan->{apply_errors}) eq 'ARRAY'
        ? $plan->{apply_errors} : [];
    for my $err (@$apply_errors) {
        next unless ref($err) eq 'HASH' && ($err->{type} // '') eq 'store';
        _pm_metric($bot, 'mediabot_plugin_store_rejected_total',
            { plugin => $key, reason => _store_rejection_reason($err->{error}) });
    }
    return;
}

# mb604-B1: pose d'une gauge best-effort — meme discipline que _pm_metric
# (sans metrics, le dispatch est inchange et rien ne meurt).
sub _pm_gauge {
    my ($bot, $name, $value, $labels) = @_;
    return unless $bot;
    my $metrics = eval { $bot->{metrics} } or return;
    return unless eval { $metrics->can('set') };
    eval { $metrics->set($name, $value, $labels) };
    return;
}

# mb598-B1: increment de metrique best-effort — jamais un die, jamais un
# prerequis : sans objet metrics (fixtures, conf sans exporter) le dispatch
# continue exactement comme avant.
sub _pm_metric {
    my ($bot, $name, $labels) = @_;
    my $metrics = eval { $bot->{metrics} };
    return unless $metrics && eval { $metrics->can('inc') };
    eval { $metrics->inc($name, $labels) };
    return;
}

sub _plugin_command_authorized {
    my ($bot, $ctx, $required) = @_;

    return 1 if !defined($required) || $required eq '0';

    my $message = eval { $ctx->message };
    return (0, 'no message context') unless $message;

    my $user = eval { Mediabot::Helpers::get_user_from_message($bot, $message) };
    return (0, 'unknown user') unless $user;
    return (0, 'not authenticated')
        unless eval { $user->is_authenticated };

    my $ok = eval {
        $bot->can('checkUserLevel')
            ? $bot->checkUserLevel($user->level, $required)
            : Mediabot::Helpers::checkUserLevel($bot, $user->level, $required);
    };
    return (0, "requires $required level") unless $ok;
    return 1;
}

sub _mount_manifest_commands {
    my ($self, $key, $entry) = @_;

    my $manifest = $entry->{manifest};
    return 1 unless $manifest && ref($manifest->{commands}) eq 'HASH'
                 && %{ $manifest->{commands} };
    my $registry = $self->{bot} && eval { $self->{bot}->can('registry') }
        ? eval { $self->{bot}->registry } : undef;
    die "PluginManager: cannot mount commands for plugin '$key': command registry unavailable\n"
        unless $registry;

    my $object = $entry->{object};
    my $kind   = $entry->{metadata}{kind} // 'module';
    if ($kind ne 'script') {
        die "PluginManager: plugin '$key' commands require a registered object\n"
            unless blessed($object);
    }
    my @mounted;
    for my $cmd (sort keys %{ $manifest->{commands} }) {
        my $spec   = $manifest->{commands}{$cmd};
        my $method = "command_$cmd";
        my $ok = eval {
            $registry->register_command(
                name        => $cmd,
                source      => 'public',
                plugin      => $key,
                level       => $spec->{level},
                description => $spec->{help},
                handler     => sub {
                    my ($ctx) = @_;
                    unless ($self->is_enabled($key)) {
                        # plugin disable : la commande se tait, tracee bas.
                        eval { $self->{bot}{logger}->log(4,
                            "plugin '$key' disabled — command '$cmd' ignored") };
                        return;
                    }
                    # mb589-B1: pont d'autorisation — verifie a CHAQUE
                    # dispatch, jamais fige au montage.
                    my ($authorized, $deny) =
                        _plugin_command_authorized($self->{bot}, $ctx, $spec->{level});
                    unless ($authorized) {
                        _pm_metric($self->{bot},
                            'mediabot_plugin_command_denied_total',
                            { plugin => $key, command => $cmd });
                        my $nick = eval { $ctx->nick } // '';
                        eval { $self->{bot}{logger}->log(3,
                            "plugin '$key' command '$cmd' denied: $deny") };
                        eval { Mediabot::Helpers::botNotice($self->{bot}, $nick,
                            "Access denied: '$cmd' requires $spec->{level} level.") }
                            if length $nick && $deny ne 'no message context';
                        return;
                    }
                    _pm_metric($self->{bot}, 'mediabot_plugin_command_total',
                        { plugin => $key, command => $cmd });
                    # mb590-B1: un plugin SCRIPT dispatche vers le protocole
                    # mediabot-script-v1 existant (run hors process + actions
                    # appliquees par ScriptActionRunner) ; un module appelle
                    # sa methode in-process comme depuis mb587.
                    return $kind eq 'script'
                        ? $self->_dispatch_script_command($key, $entry, $cmd, $ctx)
                        : $object->$method($ctx);
                },
            );
            1;
        };
        unless ($ok) {
            my $err = _plugin_error_text($@, 'register_command failed');
            $registry->unregister_command($_, 'public') for @mounted;
            die "PluginManager: mounting command '$cmd' for plugin '$key' failed: $err\n";
        }
        push @mounted, $cmd;
    }
    $entry->{mounted_commands} = \@mounted;
    return 1;
}

sub _unmount_entry_commands {
    my ($self, $entry) = @_;
    return 0 unless $entry && ref($entry->{mounted_commands}) eq 'ARRAY';
    my $registry = $self->{bot} && eval { $self->{bot}->can('registry') }
        ? eval { $self->{bot}->registry } : undef;
    return 0 unless $registry;
    $registry->unregister_command($_, 'public')
        for @{ $entry->{mounted_commands} };
    $entry->{mounted_commands} = [];
    return 1;
}

# mb593-B1: abonnement des events du manifest d'un plugin SCRIPT sur
# l'EventBus. Chaque listener verifie is_enabled a CHAQUE evenement (un
# plugin disable observe en silence... c'est-a-dire pas du tout), puis
# route vers le script par le protocole v1. Les entries rendues par on()
# sont memorisees dans l'entry pour le desabonnement exact (off() par
# reference, discipline mb242) sur tout le cycle de vie — un listener
# fantome de script serait le retour des fantomes mb233. Atomicite : un
# echec d'abonnement desabonne ceux deja poses et remonte l'erreur.
sub _subscribe_manifest_events {
    my ($self, $key, $entry) = @_;

    my $manifest = $entry->{manifest};
    return 1 unless $manifest && ref($manifest->{events}) eq 'ARRAY'
                 && @{ $manifest->{events} };
    my $bus = $self->{bot} && eval { $self->{bot}->can('events') }
        ? eval { $self->{bot}->events } : undef;
    die "PluginManager: cannot subscribe events for plugin '$key': event bus unavailable\n"
        unless $bus && eval { $bus->can('on') && $bus->can('off') };

    my @subscribed;
    for my $event (@{ $manifest->{events} }) {
        my $listener = eval {
            $bus->on($event, sub {
                my ($ctx) = @_;
                return unless $self->is_enabled($key);
                _pm_metric($self->{bot}, 'mediabot_plugin_event_total',
                    { plugin => $key, event => $event });
                return $self->_dispatch_script_event($key, $entry, $event, $ctx);
            },
            plugin => $key,
            name   => "script:" . ($entry->{metadata}{script_path} // $key) . ":$event");
        };
        unless ($listener) {
            my $err = _plugin_error_text($@, 'event subscribe failed');
            $bus->off(@$_) for @subscribed;
            die "PluginManager: subscribing event '$event' for plugin '$key' failed: $err\n";
        }
        push @subscribed, [ $event, $listener ];
    }
    $entry->{event_listeners} = \@subscribed;
    return 1;
}

sub _unsubscribe_entry_events {
    my ($self, $entry) = @_;
    return 0 unless $entry && ref($entry->{event_listeners}) eq 'ARRAY';
    my $bus = $self->{bot} && eval { $self->{bot}->can('events') }
        ? eval { $self->{bot}->events } : undef;
    return 0 unless $bus;
    $bus->off(@$_) for @{ $entry->{event_listeners} };
    $entry->{event_listeners} = [];
    return 1;
}

# mb597-B1: normaliser le contexte EventBus avant la frontiere JSON.
# Les evenements de canal portent un HASH simple, mais
# public_command_observed porte un Mediabot::Context (HASH beni). L'ancien
# test ref($ctx) eq 'HASH' vidait donc completement ce dernier. On expose une
# liste blanche de champs scalaires et args (ARRAY de scalaires), puis target
# suit channel comme dans le chemin des commandes.
sub _script_event_data {
    my ($ctx) = @_;

    my %data;
    my $storage = eval { reftype($ctx) } // '';
    if ($storage eq 'HASH') {
        for my $key (qw(event_type channel target nick ident host message topic kicked is_self command
                        new_nick minute hour dow mday month year)) {
            my $value = $ctx->{$key};
            $data{$key} = "$value" if defined $value && !ref($value);
        }
        if (ref($ctx->{args}) eq 'ARRAY') {
            my @args;
            for my $value (@{ $ctx->{args} }) {
                next unless defined $value && !ref($value);
                push @args, "$value";
                last if @args >= 64;
            }
            $data{args} = \@args;
        }
    }
    elsif (blessed($ctx)) {
        for my $key (qw(channel nick command)) {
            my $value = eval { $ctx->$key() };
            $data{$key} = "$value" if defined $value && !ref($value);
        }
        my $args = eval { $ctx->args };
        if (ref($args) eq 'ARRAY') {
            my @clean;
            for my $value (@$args) {
                next unless defined $value && !ref($value);
                push @clean, "$value";
                last if @clean >= 64;
            }
            $data{args} = \@clean;
        }
    }

    $data{target} = $data{channel}
        if !defined($data{target}) && defined($data{channel});
    return \%data;
}

sub _script_result_error {
    my ($result, $eval_error) = @_;

    if (ref($result) eq 'HASH') {
        for my $container ($result,
            (ref($result->{response}) eq 'HASH' ? $result->{response} : ())) {
            for my $key (qw(error detail stage)) {
                my $value = $container->{$key};
                return _plugin_error_text($value, 'script failed')
                    if defined $value && !ref($value) && length($value);
            }
            if (ref($container->{errors}) eq 'ARRAY') {
                my @errors;
                for my $value (@{ $container->{errors} }) {
                    next unless defined $value && !ref($value) && length($value);
                    push @errors, _plugin_error_text($value, 'script failed');
                    last if @errors >= 3;
                }
                return join('; ', @errors) if @errors;
            }
        }
        return 'script timed out' if $result->{timeout};
    }
    return _plugin_error_text($eval_error, 'script failed');
}

sub _script_event_apply_error {
    my ($plan, $eval_error) = @_;

    return _plugin_error_text($eval_error, 'action apply failed')
        unless ref($plan) eq 'HASH';
    my @errors;
    if (ref($plan->{apply_errors}) eq 'ARRAY') {
        for my $item (@{ $plan->{apply_errors} }) {
            my $value = ref($item) eq 'HASH' ? $item->{error}
                      : !ref($item)          ? $item
                      :                       undef;
            next unless defined $value && length($value);
            push @errors, _plugin_error_text($value, 'action failed');
            last if @errors >= 3;
        }
    }
    return @errors ? join('; ', @errors) : 'action apply failed';
}

# mb593-B1: dispatch d'un EVENEMENT vers un plugin SCRIPT. Meme protocole
# et memes gates que les commandes (apply + allow_irc seulement) ; en
# revanche PAS de notice en cas d'echec — un evenement n'a pas d'appelant
# a prevenir, l'echec va au journal et c'est tout. Le contexte transmis au
# script est une copie bornee du ctx observe (dont command/args pour
# public_command_observed).
sub _dispatch_script_event {
    my ($self, $key, $entry, $event, $ctx) = @_;

    my $bot    = $self->{bot};
    my $runner = eval { $bot->script_runner };
    my $ar     = eval { $bot->script_action_runner };
    return unless $runner && $ar;

    my $data = _script_event_data($ctx);

    my $result = eval {
        my $st = $self->_read_plugin_data($key);
        $runner->run_script($entry->{metadata}{script_path}, $event, %$data,
            (ref($entry->{plugin_config}) eq 'HASH' && %{ $entry->{plugin_config} }
                ? (config => $entry->{plugin_config}) : ()),
            (defined $st ? (storage => $st) : ()));
    };
    my $run_error = $@;
    unless (ref($result) eq 'HASH' && $result->{ok}) {
        my $why = _script_result_error($result, $run_error);
        _pm_metric($bot, 'mediabot_plugin_script_failure_total',
            { plugin => $key, kind => 'event' });
        eval { $bot->{logger}->log(1,
            "plugin '$key' script event '$event' failed: $why") };
        return;
    }

    my $context = { event => $event,
                    channel => $data->{channel}, target => $data->{target},
                    nick => $data->{nick} };
    my $plan;
    my $applied = eval {
        $plan = $ar->apply_actions($result, $context,
            apply => 1, allow_irc => 1,
            # mb601-B1: la gate store s'ouvre pour les plugins v2, le sink
            # ecrit atomiquement sous le nom du plugin.
            allow_store => 1,
            store_sink  => sub { $self->_store_plugin_data($key, $_[0]) });
        # mb604-B1: pourquoi une ecriture n'a pas eu lieu (plan ou application).
        _pm_store_rejections($bot, $key, $plan);
        1;
    };
    my $apply_error = $@;
    unless ($applied && ref($plan) eq 'HASH' && $plan->{applied_ok}) {
        my $why = !$applied
            ? _plugin_error_text($apply_error, 'action apply failed')
            : ref($plan) eq 'HASH'
                ? _script_event_apply_error($plan, $apply_error)
                : 'invalid action apply result';
        eval { $bot->{logger}->log(1,
            "plugin '$key' script event '$event' action apply failed: $why") };
        _pm_metric($bot, 'mediabot_plugin_script_failure_total',
            { plugin => $key, kind => 'event' });
        return;
    }
    return 1;
}

# mb590-B1: dispatch d'une commande de plugin SCRIPT — reutilise le chemin
# d'execution mediabot-script-v1 de bout en bout : run_script (gardes de
# chemin, langage perl/python/tcl, timeout, bornes stdout/actions du runner)
# puis apply_actions en vif avec apply+allow_irc SEULEMENT — les gates
# intrusives (topic/kick/ban) restent fermees par defaut, exactement comme
# le veut leur modele mb545/554/564.
sub _dispatch_script_command {
    my ($self, $key, $entry, $cmd, $ctx) = @_;

    my $bot    = $self->{bot};
    my $runner = eval { $bot->script_runner };
    my $ar     = eval { $bot->script_action_runner };
    my $nick    = eval { $ctx->nick }    // '';
    my $channel = eval { $ctx->channel } // '';
    unless ($runner && $ar) {
        eval { $bot->{logger}->log(1,
            "plugin '$key': script runtime unavailable for '$cmd'") };
        return;
    }

    my @args = eval { @{ $ctx->args || [] } };
    my $result = eval {
        $runner->run_script(
            $entry->{metadata}{script_path},
            'public_command',
            channel => $channel,
            target  => $channel,
            nick    => $nick,
            command => $cmd,
            args    => \@args,
            # mb600-B1: la config effective du plugin voyage dans data.config
            # (le runner la normalise deja — _normalize_config_map).
            (ref($entry->{plugin_config}) eq 'HASH' && %{ $entry->{plugin_config} }
                ? (config => $entry->{plugin_config}) : ()),
            do { my $st = $self->_read_plugin_data($key);
                 defined $st ? (storage => $st) : () },
        );
    };
    my $run_error = $@;
    unless (ref($result) eq 'HASH' && $result->{ok}) {
        my $why = _script_result_error($result, $run_error);
        eval { $bot->{logger}->log(1,
            "plugin '$key' script command '$cmd' failed: $why") };
        _pm_metric($bot, 'mediabot_plugin_script_failure_total',
            { plugin => $key, kind => 'command' });
        eval { Mediabot::Helpers::botNotice($bot, $nick,
            "Command '$cmd' failed (script error).") } if length $nick;
        return;
    }

    my $context = { event => 'public_command', channel => $channel,
                    target => $channel, nick => $nick,
                    command => $cmd, args => \@args };
    my $plan;
    my $applied = eval {
        $plan = $ar->apply_actions($result, $context,
            apply => 1, allow_irc => 1,
            # mb601-B1: la gate store s'ouvre pour les plugins v2, le sink
            # ecrit atomiquement sous le nom du plugin.
            allow_store => 1,
            store_sink  => sub { $self->_store_plugin_data($key, $_[0]) });
        # mb604-B1: pourquoi une ecriture n'a pas eu lieu (plan ou application).
        _pm_store_rejections($bot, $key, $plan);
        1;
    };
    unless ($applied && ref($plan) eq 'HASH' && $plan->{applied_ok}) {
        # mb591-B3: ScriptActionRunner failures are an external contract.
        # Never assume a HASH result or HASH-shaped apply_errors: old/custom
        # runners may return a scalar, and diagnostics may be plain strings.
        my $why;
        if (!$applied) {
            $why = $@ || 'action apply failed';
        }
        elsif (ref($plan) ne 'HASH') {
            $why = 'invalid action apply result';
        }
        else {
            my @errors;
            if (ref($plan->{apply_errors}) eq 'ARRAY') {
                for my $error (@{ $plan->{apply_errors} }) {
                    my $message =
                        ref($error) eq 'HASH' ? $error->{error}
                      : !ref($error)          ? $error
                      :                        undef;
                    $message = 'action failed'
                        unless defined($message) && length($message);
                    $message =~ s/[\r\n\0]+/ /g;
                    push @errors, $message;
                }
            }
            $why = @errors ? join('; ', @errors) : 'action apply failed';
        }
        $why = 'action apply failed' unless defined($why) && length($why);
        $why =~ s/[\r\n\0]+/ /g;
        eval { $bot->{logger}->log(1,
            "plugin '$key' script command '$cmd' action apply failed: $why") };
        _pm_metric($bot, 'mediabot_plugin_script_failure_total',
            { plugin => $key, kind => 'command' });
        eval { Mediabot::Helpers::botNotice($bot, $nick,
            "Command '$cmd' completed with action errors.") } if length $nick;
        return;
    }
    return 1;
}

# mb590-B1: chargement d'un plugin SCRIPT v2 — le manifest vit dans un
# fichier SIDECAR JSON obligatoire (<script>.manifest.json a cote du
# script). Le chemin passe par validate_script_path du runner (les memes
# gardes anti-traversal que toute execution), le JSON est borne et decode
# strictement, la validation reutilise _validate_manifest (method-check
# saute, documente). L'entry porte kind=script + script_path ; montage,
# cycle de vie, autorisation et demontage sont EXACTEMENT ceux des plugins
# in-process.
our $MAX_SIDECAR_BYTES = 8192;

sub load_script_v2 {
    my ($self, $rel_path, %opts) = @_;

    die "PluginManager: script path must be a plain scalar\n"
        if !defined($rel_path) || ref($rel_path) || !length($rel_path);

    my $runner = eval { $self->{bot}->script_runner }
        or die "PluginManager: no script runner available\n";

    my ($path_ok, $path_err, $language, $full_path) =
        $runner->validate_script_path($rel_path);
    die "PluginManager: invalid script path: $path_err\n" unless $path_ok;
    die "PluginManager: unsupported script language for '$rel_path'\n"
        unless $language;
    die "PluginManager: script file not found or not regular: $rel_path\n"
        unless defined $full_path && -f $full_path;

    # Use the normalized path validated by ScriptRunner for the sidecar and
    # for later execution metadata. This avoids validating one spelling and
    # opening another one.
    $rel_path = File::Spec->abs2rel($full_path, $runner->script_dir);
    $rel_path =~ s{\\}{/}g;

    (my $base = $rel_path) =~ s{.*/}{};
    $base =~ s/\.[A-Za-z0-9]+\z//;
    my $name = $opts{name} || $base;
    my $key  = _name($name);
    die "PluginManager: missing plugin name\n" unless defined $key;
    die "PluginManager: plugin '$key' already registered\n"
        if exists $self->{plugins}{$key} && !$opts{replace};

    my $sidecar = File::Spec->catfile($runner->script_dir, $rel_path)
        . '.manifest.json';
    die "PluginManager: sidecar manifest not found: $rel_path.manifest.json\n"
        unless -f $sidecar;
    my ($sidecar_ok, $sidecar_err) = $runner->_path_within_script_dir($sidecar);
    die "PluginManager: invalid sidecar path: $sidecar_err\n"
        unless $sidecar_ok;

    my $sidecar_size = -s $sidecar;
    die "PluginManager: cannot stat sidecar manifest\n"
        unless defined $sidecar_size;
    die "PluginManager: sidecar manifest larger than $MAX_SIDECAR_BYTES bytes\n"
        if $sidecar_size > $MAX_SIDECAR_BYTES;

    open my $fh, '<:raw', $sidecar
        or die "PluginManager: cannot read sidecar: $!\n";
    my $json = '';
    while (length($json) <= $MAX_SIDECAR_BYTES) {
        my $want = $MAX_SIDECAR_BYTES + 1 - length($json);
        my $n = read($fh, my $chunk, $want);
        die "PluginManager: cannot read sidecar: $!\n" unless defined $n;
        last if $n == 0;
        $json .= $chunk;
    }
    close $fh;
    die "PluginManager: sidecar manifest larger than $MAX_SIDECAR_BYTES bytes\n"
        if length($json) > $MAX_SIDECAR_BYTES;
    my $manifest = eval { JSON::PP->new->decode($json) };
    die "PluginManager: sidecar manifest is not valid JSON: "
      . _plugin_error_text($@, 'decode failed') . "\n"
        unless ref($manifest) eq 'HASH';

    my $why = $self->_validate_manifest($rel_path, $key, $manifest,
        skip_method_check => 1, script_events_routable => 1);
    die "PluginManager: manifest rejected for $rel_path: $why\n"
        if defined $why;

    # mb600-B1: config effective = defaults du sidecar surcharges par les
    # cles plugins.<name>.<KEY> de la conf du bot. SNAPSHOT au load — meme
    # philosophie que data.config des routes v1 (mb552 : config snapshotee,
    # network frais) ; .plugins reload relit sidecar ET surcharges. Une
    # surcharge invalide (ref, >512 octets) est ignoree avec trace : la
    # conf de l'operateur ne doit jamais empecher un plugin de charger.
    my $plugin_config;
    if (ref($manifest->{config}) eq 'HASH' && %{ $manifest->{config} }) {
        my %effective = %{ $manifest->{config} };
        my $conf = eval { $self->{bot}{conf} };
        if ($conf && eval { $conf->can('get') }) {
            for my $ckey (sort keys %effective) {
                my $ov = eval { $conf->get("plugins.$key.$ckey") };
                next unless defined $ov;
                if (ref($ov) || length("$ov") > 512) {
                    eval { $self->{bot}{logger}->log(2,
                        "PluginManager: ignoring invalid override plugins.$key.$ckey") };
                    next;
                }
                $effective{$ckey} = "$ov";
            }
        }
        $plugin_config = \%effective;
    }

    my $previous_entry = ($opts{replace} && exists $self->{plugins}{$key})
        ? $self->{plugins}{$key} : undef;

    my $effective_enabled = exists $opts{enabled}
        ? ($opts{enabled} ? 1 : 0)
        : ($previous_entry ? ($previous_entry->{enabled} ? 1 : 0) : 1);

    my $entry = $self->register_plugin(
        name        => $key,
        module      => "script:$rel_path",
        object      => undef,
        version     => $manifest->{version},
        description => $opts{description} // $manifest->{description},
        enabled     => $effective_enabled,
        manifest    => $manifest,
        metadata    => { kind => 'script', script_path => $rel_path },
        plugin_config => $plugin_config,
        replace     => $opts{replace},
        defer_unregister_cleanup => 1,
        defer_command_cleanup    => 1,
    );
    $entry->{metadata}{api}  = 2;
    $entry->{metadata}{kind} = 'script';
    $entry->{metadata}{script_path} = $rel_path;

    # Transactional replace: keep the previous entry/object alive until the
    # new manifest is validated and registered, then swap the registry
    # commands. If mounting fails, restore the previous entry and commands.
    # mb593-B1: les abonnements d'evenements suivent exactement le meme
    # cycle transactionnel que les commandes montees.
    if ($previous_entry) {
        $self->_unmount_entry_commands($previous_entry);
        $self->_unsubscribe_entry_events($previous_entry);
    }

    my $mounted_ok = eval {
        $self->_mount_manifest_commands($key, $entry);
        $self->_subscribe_manifest_events($key, $entry);
        1;
    };
    unless ($mounted_ok) {
        my $mount_err = _plugin_error_text($@, 'command mount failed');
        $self->_unmount_entry_commands($entry);
        $self->_unsubscribe_entry_events($entry);

        if ($previous_entry) {
            $self->{plugins}{$key} = $previous_entry;
            my $restored = eval {
                $self->_mount_manifest_commands($key, $previous_entry);
                $self->_subscribe_manifest_events($key, $previous_entry);
                1;
            };
            unless ($restored) {
                my $rollback_err = _plugin_error_text($@, 'rollback mount failed');
                die "PluginManager: $mount_err; rollback failed: $rollback_err\n";
            }
        }
        else {
            delete $self->{plugins}{$key};
            @{ $self->{order} } = grep { $_ ne $key } @{ $self->{order} };
        }
        die "PluginManager: $mount_err\n";
    }
    return $entry;
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

    # mb586-B1: manifest v2 valide AVANT tout register() (fail-closed, aucun
    # effet de bord si refus). Absence de manifest = plugin v1 legacy.
    my ($manifest, $api) = (undef, 1);
    if ($module->can('manifest')) {
        my $got = eval { $module->manifest };
        die "PluginManager: manifest call failed for $module: "
          . _plugin_error_text($@, 'manifest died') . "\n"
            unless defined $got || !$@;
        my $why = $self->_validate_manifest($module, $key, $got);
        die "PluginManager: manifest rejected for $module: $why\n" if defined $why;
        $manifest = $got;
        $api = 2;
    }

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
        die "PluginManager: failed to register $module: "
          . _plugin_error_text($@, 'plugin register failed') . "\n"
            unless $registered;
    }

    my $effective_enabled = exists $opts{enabled}
        ? ($opts{enabled} ? 1 : 0)
        : ($previous_entry ? ($previous_entry->{enabled} ? 1 : 0) : 1);

    my $entry = $self->register_plugin(
        name        => $name,
        module      => $module,
        object      => $object,
        version     => $manifest ? $manifest->{version}
                     : ($module->can('VERSION') ? $module->VERSION : undef),
        description => $opts{description}
                     // ($manifest ? $manifest->{description} : undef),
        enabled     => $effective_enabled,
        metadata    => $opts{metadata},
        manifest    => $manifest,
        replace     => $opts{replace},
        defer_unregister_cleanup => 1,
        defer_command_cleanup    => 1,
    );
    $entry->{metadata}{api} = $api;

    # Transactional replace: do not destroy the previous command surface until
    # the new object and manifest are ready. Swap the registry commands, and
    # restore the previous entry if mounting fails.
    my $previous_object = $previous_entry ? $previous_entry->{object} : undef;
    my $replacement_object = $entry->{object};
    my $replacement_is_same_object =
        _same_plugin_object($previous_object, $replacement_object);

    $self->_unmount_entry_commands($previous_entry) if $previous_entry;

    my $mounted_ok = eval { $self->_mount_manifest_commands($key, $entry); 1 };
    unless ($mounted_ok) {
        my $mount_err = _plugin_error_text($@, 'command mount failed');
        $self->_unmount_entry_commands($entry);

        if (ref($replacement_object)
            && !$replacement_is_same_object
            && eval { $replacement_object->can('unregister') }) {
            eval { $replacement_object->unregister(manager => $self) };
        }

        if ($previous_entry) {
            $self->{plugins}{$key} = $previous_entry;
            my $restored = eval {
                $self->_mount_manifest_commands($key, $previous_entry);
                1;
            };
            unless ($restored) {
                my $rollback_err = _plugin_error_text($@, 'rollback mount failed');
                die "PluginManager: $mount_err; rollback failed: $rollback_err\n";
            }
        }
        else {
            delete $self->{plugins}{$key};
            @{ $self->{order} } = grep { $_ ne $key } @{ $self->{order} };
        }
        die "PluginManager: $mount_err\n";
    }

    # mb249-B1: load_perl_module(..., replace => 1) must mirror the
    # same-object guard already present in direct register_plugin(). Some
    # plugins may return a singleton/current object from register(); in that
    # case the replacement is only a metadata refresh and calling unregister()
    # on the previous object would tear down the still-current plugin hooks.
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
