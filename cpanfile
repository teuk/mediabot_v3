# Mediabot v3 Perl dependencies used by GitHub Actions and developer tooling.
#
# Runtime source of truth: install/cpan_install.sh (PERL_MODULES).
# Module::Build is installed separately by that installer and is declared here
# as a build dependency. Hailo is intentionally handled by a dedicated CI step
# because the supported installer includes a pinned Hailo 0.75 fallback URL.

requires 'Module::Build';
requires 'Getopt::Long';
requires 'File::Basename';
requires 'IO::Async::Loop';
requires 'IO::Async::Timer::Periodic';
requires 'Net::Async::IRC';
requires 'Data::Dumper';
requires 'Config::Simple';
requires 'Date::Parse';
requires 'DBI';
requires 'DBD::MariaDB';
requires 'Switch';
requires 'Memory::Usage';
requires 'String::IRC';
requires 'DateTime';
requires 'DateTime::TimeZone';
requires 'HTML::Tree';
requires 'HTML::Entities';
requires 'URL::Encode';
requires 'Time::HiRes';
requires 'Moose';
requires 'JSON::MaybeXS';
requires 'List::Util';
requires 'File::Temp';
requires 'HTTP::Tiny';
requires 'IO::Socket::SSL';
requires 'Try::Tiny';
requires 'Crypt::Bcrypt';
requires 'URI::Escape';
requires 'Date::Format';
requires 'JSON';
requires 'File::Slurp';
