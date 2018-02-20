# -*- Mode: Perl; perl-indent-level: 2; indent-tabs-mode: nil -*-
# Copyright 2009 Ge van Geldorp
#
# This library is free software; you can redistribute it and/or
# modify it under the terms of the GNU Lesser General Public
# License as published by the Free Software Foundation; either
# version 2.1 of the License, or (at your option) any later version.
#
# This library is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
# Lesser General Public License for more details.
#
# You should have received a copy of the GNU Lesser General Public
# License along with this library; if not, write to the Free Software
# Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA 02110-1301, USA

use strict;

package WineTestBot::Config;

=head1 NAME

WineTestBot::Config - Site-independent configuration settings

=cut

use vars qw (@ISA @EXPORT @EXPORT_OK $UseSSL $LogDir $DataDir $BinDir
             $DbDataSource $DbUsername $DbPassword $MaxRevertingVMs
             $MaxRevertsWhileRunningVMs $MaxActiveVMs $MaxRunningVMs
             $MaxVMsWhenIdle
             $SleepAfterRevert $WaitForToolsInVM $MaxTaskTries $AdminEMail
             $RobotEMail
             $WinePatchToOverride $WinePatchCc $SuiteTimeout $SingleTimeout
             $BuildTimeout $ReconfigTimeout $TagPrefix
             $ProjectName $PatchesMailingList $LDAPServer
             $LDAPBindDN $LDAPSearchBase $LDAPSearchFilter
             $LDAPRealNameAttribute $LDAPEMailAttribute $AgentPort $Tunnel
             $TunnelDefaults $PrettyHostNames $JobPurgeDays $JobArchiveDays
             $WebHostName $RegistrationQ $RegistrationARE $MuninAPIKey);

require Exporter;
@ISA = qw(Exporter);
@EXPORT = qw($UseSSL $LogDir $DataDir $BinDir
             $MaxRevertingVMs $MaxRevertsWhileRunningVMs $MaxActiveVMs
             $MaxRunningVMs $MaxVMsWhenIdle $SleepAfterRevert $WaitForToolsInVM
             $MaxTaskTries $AdminEMail
             $RobotEMail $WinePatchToOverride $WinePatchCc $SuiteTimeout
             $SingleTimeout $BuildTimeout $ReconfigTimeout
             $TagPrefix $ProjectName $PatchesMailingList
             $LDAPServer $LDAPBindDN $LDAPSearchBase $LDAPSearchFilter
             $LDAPRealNameAttribute $LDAPEMailAttribute $AgentPort $Tunnel
             $TunnelDefaults $PrettyHostNames $JobPurgeDays $JobArchiveDays
             $WebHostName $RegistrationQ $RegistrationARE $MuninAPIKey);
@EXPORT_OK = qw($DbDataSource $DbUsername $DbPassword);

if ($::RootDir !~ m=^/=)
{
    require File::Basename;
    my $name0 = File::Basename::basename($0);
    print STDERR "$name0:error: \$::RootDir must be set to an absolute path\n";
    exit 1;
}

$LogDir = "$::RootDir/var";
$DataDir = "$::RootDir/var";
$BinDir = "$::RootDir/bin";

# See the ScheduleOnHost() documentation in lib/WineTestBot/Jobs.pm
$MaxRevertingVMs = 1;
$MaxRevertsWhileRunningVMs = 0;
$MaxActiveVMs = 2;
$MaxRunningVMs = 1;
$MaxVMsWhenIdle = undef;

# How long to wait for each of the 3 connection attempts to the VM's TestAgent
# server after a revert (in seconds). If there are powered off snapshots this
# must be long enough for the VM to boot up first.
$WaitForToolsInVM = 30;
# How long to let the VM settle down after the revert before starting a task on
# it (in seconds).
$SleepAfterRevert = 0;

# How many times to run a test that fails before giving up.
$MaxTaskTries = 3;

# How long to let a test suite run before forcibly shutting it down
# (in seconds).
$SuiteTimeout = 30 * 60;
# How long to let a regular test run before forcibly shutting it down
# (in seconds).
$SingleTimeout = 2 * 60;
# How long to let a regular build run before forcibly shutting it down
# (in seconds).
$BuildTimeout = 5 * 60;
# How long to let a full recompilation run before forcibly shutting it down
# (in seconds).
$ReconfigTimeout = 45 * 60;

$ProjectName = "Wine";
$PatchesMailingList = "wine-devel";

$LDAPServer = undef;
$LDAPBindDN = undef;
$LDAPSearchBase = undef;
$LDAPSearchFilter = undef;
$LDAPRealNameAttribute = undef;
$LDAPEMailAttribute = undef;

$JobPurgeDays = 7;
$JobArchiveDays = 0;

if (!$::BuildEnv)
{
  $::BuildEnv = 0;
  eval 'require "$::RootDir/ConfigLocal.pl"';
  if ($@)
  {
    print STDERR "Please create a valid $::RootDir/ConfigLocal.pl file; " .
        "use $::RootDir/lib/WineTestBot/ConfigLocalTemplate.pl as template\n";
    exit 1;
  }

  require ObjectModel::DBIBackEnd;
  ObjectModel::DBIBackEnd->UseDBIBackEnd('WineTestBot', $DbDataSource,
                                         $DbUsername, $DbPassword,
                                         { PrintError => 1, RaiseError => 1});
}

umask 002;

1;
