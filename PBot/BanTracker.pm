# File: BanTracker.pm
# Author: pragma_
#
# Purpose: Populates and maintains channel banlists by checking mode +b on
# joining channels and by tracking modes +b and -b in channels.
#
# Does NOT do banning or unbanning.

# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.

package PBot::BanTracker;

use warnings;
use strict;

use Time::HiRes qw/gettimeofday/;
use Time::Duration;
use Data::Dumper;
use Carp ();

sub new {
  if(ref($_[1]) eq 'HASH') {
    Carp::croak("Options to BanTracker should be key/value pairs, not hash reference");
  }

  my ($class, %conf) = @_;

  my $self = bless {}, $class;
  $self->initialize(%conf);
  return $self;
}

sub initialize {
  my ($self, %conf) = @_;

  $self->{pbot}    = delete $conf{pbot} // Carp::croak("Missing pbot reference to BanTracker");
  $self->{banlist} = {};

  $self->{pbot}->{registry}->add_default('text', 'bantracker', 'chanserv_ban_timeout', '604800');
  $self->{pbot}->{registry}->add_default('text', 'bantracker', 'mute_timeout',         '604800');
  $self->{pbot}->{registry}->add_default('text', 'bantracker', 'debug',                '0');

  $self->{pbot}->{commands}->register(sub { $self->dumpbans(@_) }, "dumpbans", 60);

  $self->{pbot}->{event_dispatcher}->register_handler('irc.endofnames', sub { $self->get_banlist(@_) });
  $self->{pbot}->{event_dispatcher}->register_handler('irc.banlist',    sub { $self->on_banlist_entry(@_) });
  $self->{pbot}->{event_dispatcher}->register_handler('irc.quietlist',  sub { $self->on_quietlist_entry(@_) });
}

sub dumpbans {
  my ($self, $from, $nick, $user, $host, $arguments) = @_;

  my $bans = Dumper($self->{banlist});
  return $bans;
}

sub get_banlist {
  my ($self, $event_type, $event) = @_;
  my $channel = lc $event->{event}->{args}[1];

  delete $self->{banlist}->{$channel};

  $self->{pbot}->{logger}->log("Retrieving banlist for $channel.\n");
  $event->{conn}->sl("mode $channel +b");
  $event->{conn}->sl("mode $channel +q");
  return 0;
}

sub on_banlist_entry {
  my ($self, $event_type, $event) = @_;
  my $channel   = lc $event->{event}->{args}[1];
  my $target    = lc $event->{event}->{args}[2];
  my $source    = lc $event->{event}->{args}[3];
  my $timestamp =    $event->{event}->{args}[4];

  my $ago = ago(gettimeofday - $timestamp);

  $self->{pbot}->{logger}->log("ban-tracker: [banlist entry] $channel: $target banned by $source $ago.\n");
  $self->{banlist}->{$channel}->{'+b'}->{$target} = [ $source, $timestamp ];
  return 0;
}

sub on_quietlist_entry {
  my ($self, $event_type, $event) = @_;
  my $channel   = lc $event->{event}->{args}[1];
  my $target    = lc $event->{event}->{args}[3];
  my $source    = lc $event->{event}->{args}[4];
  my $timestamp =    $event->{event}->{args}[5];

  my $ago = ago(gettimeofday - $timestamp);

  $self->{pbot}->{logger}->log("ban-tracker: [quietlist entry] $channel: $target quieted by $source $ago.\n");
  $self->{banlist}->{$channel}->{'+q'}->{$target} = [ $source, $timestamp ];
  return 0;
}

sub get_baninfo {
  my ($self, $mask, $channel, $account) = @_;
  my ($bans, $ban_account);

  $account = undef if not length $account;
  $account = lc $account if defined $account;

  if ($self->{pbot}->{registry}->get_value('bantracker', 'debug')) {
    $self->{pbot}->{logger}->log("[get-baninfo] Getting baninfo for $mask in $channel using account " . (defined $account ? $account : "[undefined]") . "\n");
  }

  my ($nick, $user, $host) = $mask =~ m/([^!]+)!([^@]+)@(.*)/;

  foreach my $mode (keys %{ $self->{banlist}->{$channel} }) {
    foreach my $banmask (keys %{ $self->{banlist}->{$channel}->{$mode} }) {
      if($banmask =~ m/^\$a:(.*)/) {
        $ban_account = lc $1;
      } else {
        $ban_account = "";
      }

      my $banmask_key = $banmask;
      $banmask = quotemeta $banmask;
      $banmask =~ s/\\\*/.*?/g;
      $banmask =~ s/\\\?/./g;

      my $banned;

      $banned = 1 if defined $account and $account eq $ban_account;
      $banned = 1 if $mask =~ m/^$banmask$/i;

      if ($banmask_key =~ m{\@gateway/web/irccloud.com} and $host =~ m{^gateway/web/irccloud.com}) {
        my ($bannick, $banuser, $banhost) = $banmask_key =~ m/([^!]+)!([^@]+)@(.*)/;

        if (lc $user eq lc $banuser) {
          $banned = 1;
        }
      }

      if ($banned) {
        if(not defined $bans) {
          $bans = [];
        }

        my $baninfo = {};
        $baninfo->{banmask} = $banmask_key;
        $baninfo->{channel} = $channel;
        $baninfo->{owner} = $self->{banlist}->{$channel}->{$mode}->{$banmask_key}->[0];
        $baninfo->{when} = $self->{banlist}->{$channel}->{$mode}->{$banmask_key}->[1];
        $baninfo->{type} = $mode;
        #$self->{pbot}->{logger}->log("get-baninfo: dump: " . Dumper($baninfo) . "\n");
        $self->{pbot}->{logger}->log("get-baninfo: $baninfo->{banmask} $baninfo->{type} in $baninfo->{channel} by $baninfo->{owner} on $baninfo->{when}\n");

        push @$bans, $baninfo;
      }
    }
  }

  return $bans;
}

sub track_mode {
  my $self = shift;
  my ($source, $mode, $target, $channel) = @_;

  $mode = lc $mode;
  $target = lc $target;
  $channel = lc $channel;

  if($mode eq "+b" or $mode eq "+q") {
    $self->{pbot}->{logger}->log("ban-tracker: $target " . ($mode eq '+b' ? 'banned' : 'quieted') . " by $source in $channel.\n");
    $self->{banlist}->{$channel}->{$mode}->{$target} = [ $source, gettimeofday ];
    $self->{pbot}->{antiflood}->devalidate_accounts($target, $channel);
  }
  elsif($mode eq "-b" or $mode eq "-q") {
    $self->{pbot}->{logger}->log("ban-tracker: $target " . ($mode eq '-b' ? 'unbanned' : 'unquieted') . " by $source in $channel.\n");
    delete $self->{banlist}->{$channel}->{$mode eq "-b" ? "+b" : "+q"}->{$target};

    if($mode eq "-b") {
      if($self->{pbot}->{chanops}->{unban_timeout}->find_index($channel, $target)) {
        $self->{pbot}->{chanops}->{unban_timeout}->remove($channel, $target);
      } elsif($self->{pbot}->{chanops}->{unban_timeout}->find_index($channel, "$target\$##stop_join_flood")) {
        # freenode strips channel forwards from unban result if no ban exists with a channel forward
        $self->{pbot}->{chanops}->{unban_timeout}->remove($channel, "$target\$##stop_join_flood");
      }
    }
    elsif($mode eq "-q") {
      if($self->{pbot}->{chanops}->{unmute_timeout}->find_index($channel, $target)) {
        $self->{pbot}->{chanops}->{unmute_timeout}->remove($channel, $target);
      }
    }
  } else {
    $self->{pbot}->{logger}->log("BanTracker: Unknown mode '$mode'\n");
  }
}

1;
