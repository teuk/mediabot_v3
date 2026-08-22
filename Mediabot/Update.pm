package Mediabot::Update;

# =============================================================================
# mb632-B1: `update` — mettre a jour Mediabot depuis GitHub, depuis IRC.
#
# Cette commande remplace le code du bot par lui-meme. Elle est donc ecrite a
# l'envers des autres : d'abord tout ce qui peut REFUSER, ensuite seulement ce
# qui agit. Les regles de refus sont des fonctions PURES (update_eligibility,
# update_decision) parce qu'elles sont la seule partie qu'on peut prouver par
# des tests — l'echange reel, lui, ne se rejoue pas dans une suite.
#
# Deroulement :
#   m update            -> DIAGNOSTIC reseau : version locale, version
#                          distante, eligibilite, mode de redemarrage.
#   m update status     -> ETAT DURABLE local du dernier updater ; aucun reseau.
#   m update now        -> execute reellement (Master, et seulement si le
#                          diagnostic est vert).
#
# Le travail lourd reste dans install/deploy_update.sh : clone, restauration
# de la configuration d'instance et des etats locaux (Hailo/media),
# verification perl -c et integrity check sur l'arbre STAGE, rotation du
# repertoire courant vers <projet>.<N>, rollback si la validation
# post-bascule echoue. On ne reecrit pas cette
# logique ici — une deuxieme implementation divergerait de la premiere.
#
# LE POINT QUI COMPTE : deploy_update.sh envoie SIGTERM au bot et NE LE
# REDEMARRE PAS. Sous systemd, mb645 impose un contrat explicite :
# Restart=always + ExitType=cgroup. Le second garde l'updater detache dans le
# cycle de vie de l'unite jusqu'a la fin de la bascule ; le premier relance
# ensuite la nouvelle release, y compris quand une ancienne version du bot
# traite SIGTERM comme une sortie propre. Lance a la main (screen, tmux,
# foreground), le bot reste ETEINT. Le script verifie ce contrat AVANT SIGTERM.
# =============================================================================

use strict;
use warnings;
use utf8;

use Cwd qw(realpath);
use File::Basename qw(basename dirname);
use File::Spec;
use JSON::PP qw(decode_json);
use POSIX qw(setsid strftime);

use Exporter 'import';
our @EXPORT_OK = qw(
    update_ctx
    update_eligibility
    update_decision
    update_status_record
    protected_paths
    restart_mode
);

# Instances ou cette commande ne doit JAMAIS s'executer.
#
# mb633-B1: la protection est un COUPLE chemin@hote, pas un chemin seul.
# Corrige une vraie erreur de mb632 : /home/mediabot/mediabot_v3 est le chemin
# d'installation NORMAL d'un mediabot — les autres serveurs (nbot.soyou.rocks
# entre autres) l'utilisent aussi. Proteger le chemin partout aurait donc
# interdit la mise a jour la ou elle est justement attendue. Ce qu'il faut
# refuser, c'est CETTE installation-la : ce chemin SUR l'hote EXACT teuk.org.
# mb634 aligne aussi install/deploy_update.sh sur cette meme regle.
#
# La conf peut AJOUTER des entrees, jamais en retirer — une protection qu'un
# fichier de conf peut desactiver n'est pas une protection. Une entree de conf
# sans « @hote » vaut pour TOUS les hotes : c'est un choix explicite de
# l'operateur, donc on le respecte.
our @BUILTIN_PROTECTED = ( { path => '/home/mediabot/mediabot_v3',
                             host => 'teuk.org' } );

sub protected_paths {
    my ($self) = @_;
    my @entries = map { { %$_ } } @BUILTIN_PROTECTED;
    my $extra = eval { $self->{conf}->get('update.PROTECTED_PATHS') };
    if (defined $extra && !ref $extra) {
        for my $item (split /[,\s]+/, $extra) {
            next unless defined $item && length $item;
            my ($p, $h) = split /\@/, $item, 2;
            next unless defined $p && length $p;
            $p =~ s{/+\z}{};
            push @entries, { path => $p,
                             (defined $h && length $h ? (host => $h) : ()) };
        }
    }
    my %seen;
    return grep { !$seen{ $_->{path} . '@' . ($_->{host} // '*') }++ } @entries;
}

# L'hote courant, en FQDN autant que possible. Plusieurs sources parce qu'une
# seule peut mentir : Sys::Hostname rend souvent le nom court, /etc/hostname
# porte parfois le FQDN. On rend TOUT ce qu'on a trouve — le comparateur
# cherche une correspondance dans la liste.
sub current_hostnames {
    my @names;
    my $h = eval { require Sys::Hostname; Sys::Hostname::hostname() };
    push @names, $h if defined $h && length $h;
    my @uname = eval { require POSIX; POSIX::uname() };
    push @names, $uname[1] if @uname > 1 && defined $uname[1] && length $uname[1];
    if (open my $fh, '<', '/etc/hostname') {
        my $line = <$fh>; close $fh;
        if (defined $line) { $line =~ s/\s+//g; push @names, $line if length $line }
    }
    my %seen;
    return grep { length $_ && !$seen{ lc $_ }++ } @names;
}

# mb634-B1: un <path>@<host> protege un HOTE ENTIER, jamais une sous-chaine.
# Normalisation volontairement minimale : casse ignoree et point DNS final
# optionnel. Ainsi `teuk.org`, `TEUK.ORG` et `teuk.org.` sont equivalents,
# mais `mediabot.teuk.org`, `foo-teuk.org` et `teuk.org.example` ne le sont pas.
sub _host_matches {
    my ($want, $names) = @_;
    return 0 unless defined $want && length $want;

    my $w = lc $want;
    $w =~ s/^\s+|\s+$//g;
    $w =~ s/\.\z//;
    return 0 unless length $w;

    for my $n (@{ $names || [] }) {
        next unless defined $n && length $n;
        my $got = lc $n;
        $got =~ s/^\s+|\s+$//g;
        $got =~ s/\.\z//;
        return 1 if $got eq $w;
    }
    return 0;
}

# --- decisions pures ---------------------------------------------------------

# Cette installation a-t-elle le droit d'etre mise a jour depuis IRC ?
# Rend (1, undef) ou (0, raison). Aucune I/O reseau, aucun effet de bord :
# c'est ce qui la rend testable, et c'est la partie qui protege le serveur.
sub update_eligibility {
    my (%p) = @_;
    my $dir       = $p{project_dir};
    my $protected = $p{protected} || [ @BUILTIN_PROTECTED ];
    my $exists    = $p{exists}    || {};

    return (0, 'project directory could not be resolved')
        unless defined $dir && length $dir;

    (my $norm = $dir) =~ s{/+\z}{};

    # mb633-B1: instance protegee = le CHEMIN *sur l'HOTE* declare. Une entree
    # sans hote vaut partout (choix explicite de l'operateur en conf).
    #
    # mb634-B1 : une entree <path>@<host> ne refuse QUE si l'hote courant
    # correspond exactement. Un hote inconnu ou un sous-domaine n'est pas
    # l'hote declare ; seul un chemin nu reste une protection tous-hotes.
    my $names = $p{hostnames} || [];
    for my $entry (@$protected) {
        my ($pn, $host) = ref $entry eq 'HASH'
            ? ($entry->{path}, $entry->{host})
            : ($entry, undef);
        next unless defined $pn && length $pn;
        $pn =~ s{/+\z}{};
        next unless $norm eq $pn;

        unless (defined $host && length $host) {
            return (0, "this installation is protected ($pn) - update it manually");
        }
        return (0, "this installation is protected ($pn on $host) - update it manually")
            if _host_matches($host, $names);
    }

    my $base = basename($norm);
    return (0, "unsafe project directory name '$base'")
        unless defined($base) && $base =~ /\A[A-Za-z0-9][A-Za-z0-9_-]*\z/;

    return (0, 'mediabot.pl not found in the project directory')
        unless $exists->{'mediabot.pl'};
    return (0, 'install/deploy_update.sh not found')
        unless $exists->{'install/deploy_update.sh'};
    return (0, 'install/deploy_update.sh is not executable')
        unless $exists->{'deploy_executable'};
    return (0, 'the parent directory is not writable (no room to rotate releases)')
        unless $exists->{'parent_writable'};

    return (1, undef);
}

# Faut-il, et peut-on, mettre a jour ? Rend une structure de decision.
# Separee de l'eligibilite parce qu'elle repond a une autre question : celle-ci
# regarde les VERSIONS, l'autre regarde la MACHINE.
sub update_decision {
    my (%p) = @_;
    my ($local, $remote) = ($p{local}, $p{remote});
    my $cmp = $p{compare};

    my %d = (local => $local, remote => $remote, available => 0, state => 'unknown');

    for my $v ($local, $remote) {
        return { %d, state => 'unreadable',
                 reason => 'version could not be determined (local or GitHub)' }
            unless defined $v && length $v && $v ne 'Undefined';
    }

    my $c = ref($cmp) eq 'CODE' ? $cmp->($local, $remote) : undef;
    return { %d, state => 'incomparable',
             reason => "cannot compare '$local' with '$remote'" }
        unless defined $c;

    return { %d, state => 'up_to_date' } if $c == 0;
    return { %d, state => 'ahead' }      if $c > 0;   # local plus recent que GitHub
    return { %d, state => 'available', available => 1 };
}

# Ici on detecte seulement si le processus a ete lance par systemd pour
# l'affichage IRC. La garantie de redemarrage, elle, n'est jamais supposee :
# deploy_update.sh interroge la vraie unite (Restart + ExitType) et refuse
# AVANT SIGTERM si le contrat mb645 n'est pas actif.
sub restart_mode {
    my ($env) = @_;
    $env ||= \%ENV;
    return 'systemd' if defined $env->{INVOCATION_ID} && length $env->{INVOCATION_ID};
    return 'systemd' if defined $env->{JOURNAL_STREAM} && length $env->{JOURNAL_STREAM};
    return 'manual';
}

# --- la commande -------------------------------------------------------------

sub _project_dir {
    my ($self) = @_;
    my $dir = eval { realpath(dirname(dirname(__FILE__))) };
    return $dir;
}

sub _exists_map {
    my ($dir) = @_;
    my $deploy = File::Spec->catfile($dir, 'install', 'deploy_update.sh');
    return {
        'mediabot.pl'              => (-f File::Spec->catfile($dir, 'mediabot.pl') ? 1 : 0),
        'install/deploy_update.sh' => (-f $deploy ? 1 : 0),
        'deploy_executable'        => (-x $deploy ? 1 : 0),
        'parent_writable'          => (-w dirname($dir) ? 1 : 0),
    };
}

# --- notification post-update ------------------------------------------------

# Le processus qui lance l'update meurt pendant la bascule. Pour pouvoir dire
# « update completed » APRES le restart, deploy_update.sh pose un petit marqueur
# dans le nouvel arbre uniquement une fois la validation live terminee.
#
# Le marqueur est volontairement dans var/ du NOUVEL arbre : un echec avant
# activation ou un rollback ne peut donc jamais produire un faux succes IRC.
sub _completion_marker_path {
    my ($self) = @_;
    my $dir = _project_dir($self);
    return undef unless defined $dir && length $dir;
    return File::Spec->catfile($dir, 'var', 'update.completed.json');
}

sub _read_local_version {
    my ($self) = @_;
    my $dir = _project_dir($self);
    return undef unless defined $dir && length $dir;

    my $path = File::Spec->catfile($dir, 'VERSION');
    open my $fh, '<:encoding(UTF-8)', $path or return undef;
    my $version = <$fh>;
    close $fh;
    return undef unless defined $version;
    $version =~ s/[\r\n]+\z//;
    $version =~ s/^\s+|\s+$//g;
    return length($version) ? $version : undef;
}

# mb680: unlike update.completed.json (which is a one-shot IRC notification),
# the updater status is durable and lives BESIDE the rotating release tree.
# mediabot_v3 can become mediabot_v3.N during activation, so keeping this file
# inside var/ would make the truth move with the old release exactly when it is
# most useful.  One deployment root => one stable sibling status file.
sub _update_status_path {
    my ($self) = @_;
    my $dir = _project_dir($self);
    return undef unless defined $dir && length $dir;

    return File::Spec->catfile(
        dirname($dir),
        '.' . basename($dir) . '.update-status.json',
    );
}

sub _status_scalar_safe {
    my ($value, $max) = @_;
    return 1 unless defined $value;
    return 0 if ref $value;
    return 0 if length($value) > $max;
    return 0 if $value =~ /[\x00-\x1f\x7f]/;
    return 1;
}

# Public structured reader for IRC today and Doctor/other read-only diagnostics
# later.  No network, no mutation, and no attempt to infer history from Git.
sub update_status_record {
    my ($self) = @_;

    my $path = _update_status_path($self);
    return (undef, 'status path could not be resolved')
        unless defined $path && length $path;
    return (undef, 'no update status recorded')
        unless -f $path;

    open my $fh, '<:raw', $path
        or return (undef, 'update status record could not be read');
    local $/;
    my $raw = <$fh>;
    close $fh;

    my $data = eval { decode_json($raw // '') };
    return (undef, 'invalid update status record')
        unless ref($data) eq 'HASH'
            && ($data->{schema} // 0) == 1;

    my %state_ok = map { $_ => 1 } qw(running success failed rolled_back);
    return (undef, 'invalid update status state')
        unless defined($data->{state})
            && !ref($data->{state})
            && $state_ok{ $data->{state} };

    return (undef, 'invalid update status phase')
        unless defined($data->{phase})
            && !ref($data->{phase})
            && $data->{phase} =~ /\A[a-z][a-z0-9_]{0,63}\z/;

    return (undef, 'invalid update status start time')
        unless defined($data->{started_at})
            && !ref($data->{started_at})
            && $data->{started_at} =~ /\A\d+\z/
            && $data->{started_at} > 0;

    if (defined $data->{finished_at}) {
        return (undef, 'invalid update status finish time')
            if ref($data->{finished_at})
                || $data->{finished_at} !~ /\A\d+\z/
                || $data->{finished_at} < $data->{started_at};
    }

    if (defined $data->{updater_pid}) {
        return (undef, 'invalid update status updater pid')
            if ref($data->{updater_pid})
                || $data->{updater_pid} !~ /\A\d+\z/
                || $data->{updater_pid} <= 0;
    }

    for my $key (qw(old_version target_version installed_version)) {
        return (undef, "invalid update status $key")
            unless _status_scalar_safe($data->{$key}, 128);
    }
    return (undef, 'invalid update status detail')
        unless _status_scalar_safe($data->{detail}, 400);

    return ($data, undef);
}

sub _format_update_status_time {
    my ($epoch) = @_;
    return 'unknown'
        unless defined $epoch && !ref($epoch) && $epoch =~ /\A\d+\z/ && $epoch > 0;
    my $text = eval { strftime('%Y-%m-%d %H:%M:%S %Z', localtime($epoch)) };
    return defined($text) && length($text) ? $text : "$epoch";
}

sub _show_update_status {
    my ($ctx) = @_;
    my $self = $ctx->bot;

    _say($ctx, "\x02Mediabot update status\x02");
    _say($ctx, '  local: ' . (_read_local_version($self) // 'unknown'));

    my ($data, $why) = update_status_record($self);
    unless ($data) {
        my $none = defined($why) && $why eq 'no update status recorded';
        _say($ctx, $none
            ? "\x0308  last: no durable update record yet\x0f"
            : "\x0304  last: unavailable\x0f - " . ($why // 'unknown reason'));
        return 1;
    }

    my %label = (
        running     => 'RUNNING',
        success     => 'SUCCESS',
        failed      => 'FAILED',
        rolled_back => 'ROLLED BACK',
    );
    _say($ctx, sprintf('  last: %s  |  phase: %s',
        $label{ $data->{state} } // uc($data->{state}),
        $data->{phase}));

    my $from = $data->{old_version};
    my $to = $data->{installed_version} // $data->{target_version};
    if (defined($from) || defined($to)) {
        _say($ctx, sprintf('  version: %s -> %s',
            defined($from) && length($from) ? $from : '?',
            defined($to)   && length($to)   ? $to   : '?'));
    }

    _say($ctx, '  started: ' . _format_update_status_time($data->{started_at}));
    _say($ctx, '  finished: ' . _format_update_status_time($data->{finished_at}))
        if defined $data->{finished_at};
    _say($ctx, '  detail: ' . $data->{detail})
        if defined($data->{detail}) && length($data->{detail});

    return 1;
}

sub _safe_notice_target {
    my ($kind, $target) = @_;
    return 0 unless defined $kind && ($kind eq 'channel' || $kind eq 'notice');
    return 0 unless defined $target && length $target && length($target) <= 200;
    return 0 if $target =~ /[\x00\r\n]/;
    return 0 if $kind eq 'channel' && $target !~ /^[#&+!]/;
    return 1;
}

sub _load_completion_notice {
    my ($self) = @_;

    return $self->{_update_completion_notice}
        if ref($self->{_update_completion_notice}) eq 'HASH';
    return undef if $self->{_update_completion_notice_checked};
    $self->{_update_completion_notice_checked} = 1;

    my $path = _completion_marker_path($self);
    return undef unless defined $path && -f $path;

    open my $fh, '<:raw', $path or do {
        eval { $self->{logger}->log(1, "update completion: cannot read $path: $!") };
        return undef;
    };
    local $/;
    my $raw = <$fh>;
    close $fh;

    my $data = eval { decode_json($raw // '') };
    unless (ref($data) eq 'HASH'
        && ($data->{schema} // 0) == 1
        && _safe_notice_target($data->{kind}, $data->{target})
        && defined($data->{version}) && length($data->{version}) <= 128
        && $data->{version} !~ /[\x00\r\n]/) {
        eval { $self->{logger}->log(1, 'update completion: invalid marker discarded') };
        unlink $path;
        return undef;
    }

    # Un vieux marqueur ne doit jamais annoncer une version qui n'est plus
    # celle du processus courant (par exemple apres une mise a jour manuelle).
    my $local = _read_local_version($self);
    unless (defined $local && $local eq $data->{version}) {
        eval { $self->{logger}->log(1,
            'update completion: stale marker discarded (marker=' .
            ($data->{version} // '?') . ', local=' . ($local // '?') . ')') };
        unlink $path;
        return undef;
    }

    $data->{_path} = $path;
    $self->{_update_completion_notice} = $data;
    return $data;
}

sub _finish_completion_notice {
    my ($self, $data) = @_;
    return 0 unless ref($data) eq 'HASH';
    my $path = $data->{_path};
    unlink $path if defined $path && -f $path;
    delete $self->{_update_completion_notice};
    return 1;
}

sub _completion_message {
    my ($version) = @_;
    return "\x0309Update completed.\x0f Version: \x02$version\x02";
}

# Appel au login uniquement pour une commande lancee en prive. Pour une cible
# canal, on attend le JOIN reel du bot : envoyer avant le JOIN echouerait sur
# les canaux +n et casserait precisement la garantie recherchee.
sub update_completion_on_login {
    my ($self) = @_;
    my $data = _load_completion_notice($self) or return 0;
    return 0 unless $data->{kind} eq 'notice';

    Mediabot::Helpers::botNotice($self, $data->{target},
        _completion_message($data->{version}));
    _finish_completion_notice($self, $data);
    eval { $self->{logger}->log(1,
        "update completion: notified $data->{target} version $data->{version}") };
    return 1;
}

# Pour une commande lancee sur un canal, la notification part au premier JOIN
# de CE canal par le nouveau processus. C'est restart-safe et compatible avec
# l'authentification Undernet/Libera et les JOINs throttles.
sub update_completion_on_join {
    my ($self, $channel) = @_;
    return 0 unless defined $channel && length $channel;

    my $data = _load_completion_notice($self) or return 0;
    return 0 unless $data->{kind} eq 'channel';
    return 0 unless lc($data->{target}) eq lc($channel);

    Mediabot::Helpers::botPrivmsg($self, $channel,
        _completion_message($data->{version}));
    _finish_completion_notice($self, $data);
    eval { $self->{logger}->log(1,
        "update completion: notified $channel version $data->{version}") };
    return 1;
}

sub update_ctx {
    my ($ctx) = @_;

    my $self = $ctx->bot;
    my $nick = $ctx->nick;

    # [1] Niveau : Master. Pose en premier, avant toute lecture de version ou
    # de disque — une commande de cette portee ne se documente pas non plus a
    # qui n'y a pas droit.
    return unless $ctx->require_level('Master');

    my @args = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();
    my $verb = lc($args[0] // '');
    my $do_it = ($verb eq 'now' || $verb eq 'go' || $verb eq 'confirm') ? 1 : 0;

    if (length $verb && !$do_it && $verb ne 'check' && $verb ne 'status') {
        _say($ctx, "update: unknown option '$verb'. Usage: update [check|status|now]");
        return 1;
    }

    # mb680: status is deliberately LOCAL-ONLY.  It must remain useful when
    # GitHub is unreachable and even on an installation where applying the
    # built-in updater is intentionally forbidden.
    return _show_update_status($ctx) if $verb eq 'status';

    # Sortie : sur le canal si la commande y est lancee, en prive sinon.
    # (Demande explicite : « m update » informe le canal, « /msg bot update »
    # repond en prive.)
    _say($ctx, "\x02Mediabot update\x02 - checking...");

    # [2] Eligibilite de la MACHINE, avant tout appel reseau.
    my $dir = _project_dir($self);
    my ($ok, $why) = update_eligibility(
        project_dir => $dir,
        protected   => [ protected_paths($self) ],
        hostnames   => [ current_hostnames() ],
        exists      => defined $dir ? _exists_map($dir) : {},
    );
    unless ($ok) {
        _say($ctx, "\x0304Refused\x0f: $why");
        _log($self, $ctx, 'refused', $why);
        return 1;
    }

    my $mode = restart_mode();

    # [3] Versions : appel GitHub NON BLOQUANT (getVersion_async fait le
    # travail dans un fils, la boucle IRC continue de tourner).
    my $done = sub {
        my ($local, $remote, $why) = @_;   # mb638-B1: $why = pourquoi le distant manque

        my $decision = update_decision(
            local   => $local,
            remote  => $remote,
            compare => Mediabot::Helpers->can('_compare_mediabot_versions'),
        );

        # Guillemets DOUBLES : entre apostrophes, « \x02 » sortirait tel quel
        # sur le canal (piege deja rencontre en mb629).
        _say($ctx, sprintf("  local: \x02%s\x02  |  github: \x02%s\x02",
            $decision->{local}  // 'unknown',
            $decision->{remote} // 'unknown'));

        # mb638-B1: dire CE QUI a echoue. « version could not be determined »
        # ne donnait aucune prise a l'operateur : selon le cas c'est un
        # pare-feu, un proxy, une route IPv6 morte, ou IO::Socket::SSL absent.
        my $unreadable = "\x0304Cannot check\x0f: ";
        if (defined $remote && $remote ne 'Undefined' or !defined $why) {
            $unreadable .= ($decision->{reason} // 'version could not be determined');
        }
        else {
            $unreadable .= "GitHub version unavailable - $why";
        }

        my %msg = (
            unreadable   => $unreadable,
            incomparable => "\x0304Cannot compare\x0f: " . ($decision->{reason} // ''),
            up_to_date   => "\x0309Already up to date.\x0f Nothing to do.",
            ahead        => "\x0308Local build is NEWER than GitHub.\x0f Refusing to downgrade.",
        );
        if ($decision->{state} ne 'available') {
            _say($ctx, $msg{ $decision->{state} } // 'Unknown version state.');
            if ($decision->{state} eq 'unreadable' && defined $why) {
                my @sources = eval { Mediabot::Helpers::_remote_version_urls($self) };
                @sources = @Mediabot::Helpers::VERSION_URLS unless @sources;
                _say($ctx, '  version source' . (@sources > 1 ? 's: ' : ': ')
                    . join(' -> ', @sources)
                    . ' (set conf update.VERSION_URL to override)');
            }
            _log($self, $ctx, 'check',
                $decision->{state} . (defined $why ? " ($why)" : ''));
            return;
        }

        _say($ctx, "\x0309An update is available.\x0f");

        unless ($do_it) {
            _say($ctx, "  restart after update: " . ($mode eq 'systemd'
                ? "\x0309systemd\x0f (restart policy is verified before shutdown)"
                : "\x0308manual\x0f - the bot will STAY DOWN until you start it again"));
            _say($ctx, "  run \x02update now\x02 to apply it "
                     . "(instance config/state are preserved, previous release archived)");
            _log($self, $ctx, 'check', 'available');
            return;
        }

        # [4] Execution. Le script tue le bot : on annonce AVANT, et on lance
        # un processus DETACHE (setsid) qui survivra a notre propre mort.
        _say($ctx, "\x02Updating now.\x02 Preserving instance config/state, then restarting"
                 . ($mode eq 'systemd'
                    ? ' via systemd (policy checked before shutdown).'
                    : ' - START ME AGAIN afterwards.'));
        _log($self, $ctx, 'start', ($decision->{remote} // '?'));

        my $log = File::Spec->catfile($dir, 'var', 'update.log');
        my $reply_channel = eval { $ctx->channel };
        my $notify = (defined $reply_channel && $reply_channel =~ /^#/ )
            ? { kind => 'channel', target => $reply_channel }
            : { kind => 'notice',  target => $nick };
        my $rc  = _spawn_updater($self, $dir, $log, $notify);
        unless ($rc) {
            _say($ctx, "\x0304Failed to launch the updater.\x0f Nothing was changed.");
            _log($self, $ctx, 'spawn_failed', '');
            return;
        }
        _say($ctx, "  updater started - progress in $log");
    };

    # mb639: laisser getVersion_async calculer son budget depuis
    # VERSION_TIMEOUT et le nombre reel d'URL. Un timeout externe fixe a 8 s
    # annulait la tentative juste avant le miroir dans le pire cas.
    my $started = eval { Mediabot::Helpers::getVersion_async($self, $done) };
    unless ($started) {
        _say($ctx, "\x0304Cannot check versions right now.\x0f Nothing was changed.");
        _log($self, $ctx, 'check', 'unavailable');
    }
    return 1;
}

# Lance deploy_update.sh hors de notre arbre de processus : il va nous tuer,
# il ne doit donc etre ni notre fils actif, ni partager notre session.
sub _spawn_updater {
    my ($self, $dir, $log, $notify) = @_;

    my $script = File::Spec->catfile($dir, 'install', 'deploy_update.sh');
    my $vardir = dirname($log);
    mkdir $vardir unless -d $vardir;

    my $pid = fork();
    return 0 unless defined $pid;

    if ($pid == 0) {
        # Fils : on se detache completement (nouvelle session, plus de
        # terminal de controle, plus de lien avec le bot qui va mourir).
        setsid();
        chdir $dir or POSIX::_exit(1);
        open(STDIN,  '<', '/dev/null');
        open(STDOUT, '>>', $log) or open(STDOUT, '>', '/dev/null');
        open(STDERR, '>&', \*STDOUT);
        # Un second fork evite de laisser un zombie si le bot disparait avant
        # d'avoir moissonne le premier.
        my $second = fork();
        POSIX::_exit(0) if $second;      # le premier fils sort tout de suite

        if (ref($notify) eq 'HASH'
            && _safe_notice_target($notify->{kind}, $notify->{target})) {
            $ENV{MEDIABOT_UPDATE_NOTIFY_KIND}   = $notify->{kind};
            $ENV{MEDIABOT_UPDATE_NOTIFY_TARGET} = $notify->{target};
        }
        else {
            delete $ENV{MEDIABOT_UPDATE_NOTIFY_KIND};
            delete $ENV{MEDIABOT_UPDATE_NOTIFY_TARGET};
        }

        if (defined $second) {
            my @exec = ($script);
            my $config_file = $self->{config_file};
            if (defined $config_file && !ref($config_file) && length($config_file)) {
                push @exec, '--conf=' . $config_file;
            }
            exec { $script } @exec;
        }
        POSIX::_exit(1);
    }

    waitpid($pid, 0);                    # moisson immediate du premier fils
    return 1;
}

sub _say {
    my ($ctx, $text) = @_;
    my $self = $ctx->bot;
    my $nick = $ctx->nick;
    my $chan = eval { $ctx->channel };

    if (defined $chan && $chan =~ /^#/) {
        Mediabot::Helpers::botPrivmsg($self, $chan, $text);
    }
    else {
        Mediabot::Helpers::botNotice($self, $nick, $text);
    }
    return 1;
}

sub _log {
    my ($self, $ctx, $action, $detail) = @_;
    eval { Mediabot::Helpers::logBot($self, $ctx->message, undef, 'update',
                                     join(' ', grep { defined && length } $action, $detail)) };
    eval { $self->{logger}->log(1, "update: $action " . ($detail // '')) };
    return 1;
}

1;
