package Mediabot::BuiltinCommandCatalog;

use strict;
use warnings;
use utf8;

use Exporter qw(import);

our @EXPORT_OK = qw(
    public_command_names
    private_command_names
    direct_public_command_names
    legacy_public_adapter_names
    legacy_private_adapter_names
    catalogue_entries
);

# MB749 keeps one declarative catalogue for every built-in name. Executable
# handlers are registered directly in CommandRegistry by Mediabot.pm; there is
# no longer a second public or private dispatch table.
my @PUBLIC_CATALOGUE = qw(
    die nick addtimer remtimer timers msg say act cstat status echo adduser
    useradd deluser users userinfo addhost addchan chanset purge part join add
    del modinfo op deop invite voice devoice kick ban kickban kb unban bans
    showcommands chaninfo chanlist channels channellist whoami auth verify
    access addcmd remcmd modcmd mvcmd chowncmd showcmd chanstatlines whotalk
    whotalks countcmd topcmd popcmd searchcmd lastcmd owncmd holdcmd addcatcmd
    chcatcmd topsay checkhostchan checkhost checknick greet nicklist rnick
    birthdate colors seen stats top calc convert 8ball remind remindlist tell
    calclast wordcount alias streak slap karma karmatop karmareset karmadiff
    karmgraph triviastop karmawatch remindsnooze karmainfo triviareset
    triviatop pollextend karmahist roll flip choose morse abbrev compare
    heatmap monthstats define trivia triviascore active when achievements
    achievs profil profile radar actualites actualite actu news rss vdm dtc
    bashfr dashboard chanstats duel horoscope horo compat affinity quotegame
    qg mood milestone milestones ambiance leaderboard lb awards yearbook
    chronos chrono timeline features capabilities caps observatory obs recap
    onthisday otd memory learn whatis forget factoids factoid quotecount
    topquote halloffame last poll vote pollresult pollstatus pollvoters unvote
    pollstop note notes date weather meteo addbadword rembadword ignores ignore
    unignore yt song radiostatus radiomounts listeners nextsong deltrack play
    rplay radioimport radioimportdir radioqueue queue radiocheck radiocache
    radiocacheprune radiodlstatus radiodlcancel radiopush radioskip radioflush
    addresponder delresponder lastcom q quote moduser antifloodset leet rehash
    mp3 exec qlog hailo hailo_ignore hailo_unignore hailo_status hailo_chatter
    whereis birthday f xlogin tellme chatgpt openai ai claude gemini yomomma
    resolve tmdb tmdblangset debug version uptime help commands spike update
);

my @PRIVATE_CATALOGUE = qw(
    pass ident topic update debug status radiostatus radiomounts echo die nick
    addtimer remtimer timers register msg dump say act song play radioimport
    commands radioqueue radiopush radioskip radioflush adduser useradd deluser
    users cstat login logout userinfo addhost addchan chanset purge part join
    add del modinfo op deop invite voice devoice kick showcommands chaninfo
    chanlist channels channellist whoami auth verify access addcmd remcmd modcmd
    mvcmd chowncmd showcmd chanstatlines whotalk whotalks countcmd topcmd popcmd
    searchcmd lastcmd owncmd holdcmd addcatcmd chcatcmd topsay checkhostchan
    checkhost checknick greet nicklist rnick birthdate ignores ignore unignore
    lastcom moduser antifloodset rehash ai claude
);

# The first four native handlers predated MB741. The new hailo operator
# command has no legacy public handler to fall back to. All existing
# migratable public built-ins retain their original migration eligibility.
my %NO_MIGRATION_FALLBACK = map { $_ => 1 } qw(version uptime help commands hailo);

sub public_command_names {
    return @PUBLIC_CATALOGUE;
}

sub private_command_names {
    return @PRIVATE_CATALOGUE;
}

sub direct_public_command_names {
    return @PUBLIC_CATALOGUE;
}

# Compatibility exports retained for out-of-tree inventory consumers. MB749
# deliberately makes both lists empty: compatibility dispatch is retired.
sub legacy_public_adapter_names {
    return ();
}

sub legacy_private_adapter_names {
    return ();
}

sub catalogue_entries {
    my @entries;

    push @entries, map {
        +{
            name               => $_,
            source             => 'public',
            dispatch           => 'registry',
            migration_fallback => $NO_MIGRATION_FALLBACK{$_} ? 0 : 1,
        }
    } @PUBLIC_CATALOGUE;

    push @entries, map {
        +{
            name     => $_,
            source   => 'private',
            dispatch => 'registry',
        }
    } @PRIVATE_CATALOGUE;

    return @entries;
}

1;
