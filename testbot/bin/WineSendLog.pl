#!/usr/bin/perl -Tw
# -*- Mode: Perl; perl-indent-level: 2; indent-tabs-mode: nil -*-
#
# Sends the job log to the submitting user and informs the Wine Patches web
# site of the test results.
#
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

sub BEGIN
{
  if ($0 !~ m=^/=)
  {
    # Turn $0 into an absolute path so it can safely be used in @INC
    require Cwd;
    $0 = Cwd::cwd() . "/$0";
  }
  if ($0 =~ m=^(/.*)/[^/]+/[^/]+$=)
  {
    $::RootDir = $1;
    unshift @INC, "$::RootDir/lib";
  }
}
my $Name0 = $0;
$Name0 =~ s+^.*/++;


use Algorithm::Diff;

use WineTestBot::Config;
use WineTestBot::Jobs;
use WineTestBot::Log;
use WineTestBot::LogUtils;
use WineTestBot::StepsTasks;


my $PART_BOUNDARY = "==13F70BD1-BA1B-449A-9CCB-B6A8E90CED47==";


#
# Logging and error handling helpers
#

my $Debug;
sub Debug(@)
{
  print STDERR @_ if ($Debug);
}

sub DebugTee($@)
{
  my ($File) = shift;
  print $File @_;
  Debug(@_);
}

my $LogOnly;
sub Error(@)
{
  print STDERR "$Name0:error: ", @_ if (!$LogOnly);
  LogMsg @_;
}


#
# Log analysis
#

sub IsBotFailure($)
{
  my ($ErrLine) = @_;

  return ($ErrLine =~ m/Can't set VM status to running/ ||
          $ErrLine =~ m/Can't copy exe to VM/ ||
          $ErrLine =~ m/Can't copy log from VM/ ||
          $ErrLine =~ m/Can't copy generated executable from VM/);
}

sub CheckErrLog($)
{
  my ($ErrLogFileName) = @_;

  my $BotFailure = !1;
  my $Messages = "";
  if (open ERRFILE, "$ErrLogFileName")
  {
    my $Line;
    while (defined($Line = <ERRFILE>))
    {
      if (IsBotFailure($Line))
      {
        if (! $Messages)
        {
          $BotFailure = 1;
        }
      }
      else
      {
        $Messages .= $Line;
      }
    }
    close ERRFILE;
  }

  return ($BotFailure, $Messages);
}

sub ReadLog($$$)
{
  my ($LogName, $BaseName, $TestSet) = @_;

  my @Messages;
  if (open LOG, "<$LogName")
  {
    my $Line;
    my $Found = !1;
    while (! $Found && defined($Line = <LOG>))
    {
      $Found = ($Line =~ m/${BaseName}:${TestSet} start/);
    }
    if ($Found)
    {
      $Found = !1;
      while (! $Found && defined($Line = <LOG>))
      {
        $Line =~ s/[\r\n]*$//;
        if ($Line =~ m/${BaseName}:${TestSet}(?::[0-9a-f]+)? done/)
        {
          if ($Line =~ m/${BaseName}:${TestSet}(?::[0-9a-f]+)? done \(258\)/)
          {
            push @Messages, "The test timed out";
          }
          $Found = 1;
        }
        else
        {
          push @Messages, $Line;
        }
      }
    }

    close LOG;
  }
  else
  {
    Error "Unable to open '$LogName' for reading: $!\n";
  }

  return \@Messages;
}

sub GetLineKey($)
{
  my ($Line) = @_;

  $Line =~ s/^([\w_.]+:)\d+(:.*)$/$1$2/;

  return $Line;
}

sub CompareLogs($$$$)
{
  my ($SuiteLog, $TaskLog, $BaseName, $TestSet) = @_;

  my $Messages = "";

  my $SuiteMessages = ReadLog($SuiteLog, $BaseName, $TestSet);
  my $TaskMessages = ReadLog($TaskLog, $BaseName, $TestSet);

  my $Diff = Algorithm::Diff->new($SuiteMessages, $TaskMessages,
                                  { keyGen => \&GetLineKey });
  while ($Diff->Next())
  {
    if (! $Diff->Same())
    {
      foreach my $Line ($Diff->Items(2))
      {
        if ($Line =~ m/: Test failed: / || 
            $Line =~ m/: unhandled exception [0-9a-fA-F]{8} at / ||
            $Line =~ m/The test timed out/)
        {
          $Messages .= "$Line\n";
        }
      }
    }
  }

  return $Messages;
}

sub SendLog($)
{
  my ($Job) = @_;

  my $To = $WinePatchToOverride || $Job->GetEMailRecipient();
  if (! defined($To))
  {
    return;
  }

  my $StepsTasks = CreateStepsTasks(undef, $Job);
  my @SortedKeys = sort { $a <=> $b } @{$StepsTasks->GetKeys()};

  my $JobURL = ($UseSSL ? "https://" : "http://") .
               "$WebHostName/JobDetails.pl?Key=". $Job->GetKey();


  #
  # Send a job summary and all the logs as attachments to the developer
  #

  Debug("-------------------- Developer email --------------------\n");
  my $Sendmail;
  if ($Debug)
  {
    open($Sendmail, ">>&=", 1);
  }
  else
  {
    open($Sendmail, "|-", "/usr/sbin/sendmail -oi -t -odq");
  }
  print $Sendmail "From: $RobotEMail\n";
  print $Sendmail "To: $To\n";
  my $Subject = "TestBot job " . $Job->Id . " results";
  my $Description = $Job->GetDescription();
  if ($Description)
  {
    $Subject .= ": " . $Description;
  }
  print $Sendmail "Subject: $Subject\n";
  if ($Job->Patch and $Job->Patch->MessageId)
  {
    print $Sendmail "In-Reply-To: ", $Job->Patch->MessageId, "\n";
    print $Sendmail "References: ", $Job->Patch->MessageId, "\n";
  }
  print $Sendmail <<"EOF";
MIME-Version: 1.0
Content-Type: multipart/mixed; boundary="$PART_BOUNDARY"

--$PART_BOUNDARY
Content-Type: text/plain; charset="UTF-8"
MIME-Version: 1.0
Content-Transfer-Encoding: 8bit
Content-Disposition: inline

VM                   Status   Failures Command
EOF
  foreach my $Key (@SortedKeys)
  {
    my $StepTask = $StepsTasks->GetItem($Key);

    my $TestFailures = $StepTask->TestFailures;
    $TestFailures = "" if (!defined $TestFailures);
    my $Status = $StepTask->Status;
    $Status = $TestFailures ? "failed" : "success" if ($Status eq "completed");
    my $Cmd = "";
    $Cmd = $StepTask->FileName ." " if ($StepTask->FileType =~ /^exe/);
    $Cmd .= $StepTask->CmdLineArg if (defined $StepTask->CmdLineArg);

    printf $Sendmail "%-20s %-8s %-8s %s\n", $StepTask->VM->Name, $Status,
                     $TestFailures, $Cmd;
  }

  print $Sendmail "\nYou can also see the results at:\n$JobURL\n\n";

  # Print the job summary
  my @FailureKeys;
  foreach my $Key (@SortedKeys)
  {
    my $StepTask = $StepsTasks->GetItem($Key);
    my $TaskDir = $StepTask->GetTaskDir();

    print $Sendmail "\n=== ", $StepTask->GetTitle(), " ===\n";

    my $LogFiles = GetLogFileNames($TaskDir);
    my $LogName = $LogFiles->[0] || "log";
    if (open LOGFILE, "<$TaskDir/$LogName")
    {
      my $HasLogEntries = !1;
      my $PrintedSomething = !1;
      my $CurrentDll = "";
      my $PrintedDll = "";
      my $Line;
      while (defined($Line = <LOGFILE>))
      {
        $HasLogEntries = 1;
        $Line =~ s/\s*$//;
        if ($Line =~ m/^([^:]+):[^ ]+ start [^ ]+ -$/)
        {
          $CurrentDll = $1;
        }
        my $Category = $LogName =~ /\.report$/ ?
                       GetReportLineCategory($Line) :
                       GetLogLineCategory($Line);
        if ($Category eq "error")
        {
          if ($PrintedDll ne $CurrentDll)
          {
            print $Sendmail "\n$CurrentDll:\n";
            $PrintedDll = $CurrentDll;
          }
          if ($Line =~ m/^[^:]+:([^ ]+)(?::[0-9a-f]+)? done \(258\)/)
          {
            print $Sendmail "$1: The test timed out\n";
          }
          else
          {
            print $Sendmail "$Line\n";
          }
          $PrintedSomething = 1;
        }
      }
      close LOGFILE;

      if (open ERRFILE, "<$TaskDir/err")
      {
        my $First = 1;
        while (defined($Line = <ERRFILE>))
        {
          if ($First)
          {
            print $Sendmail "\n";
            $First = !1;
          }
          $HasLogEntries = 1;
          $Line =~ s/\s*$//;
          print $Sendmail "$Line\n";
          $PrintedSomething = 1;
        }
        close ERRFILE;
      }

      if (! $PrintedSomething)
      {
        if (! $HasLogEntries)
        {
          print $Sendmail "Empty test log and no error message\n";
        }
        elsif ($StepTask->Type eq "build")
        {
          print $Sendmail "No build failures found\n";
        }
        else
        {
          print $Sendmail "No test failures found\n";
        }
      }
      else
      {
        push @FailureKeys, $Key;
      }
    }
    elsif (open ERRFILE, "<$TaskDir/err")
    {
      my $HasErrEntries = !1;
      my $Line;
      while (defined($Line = <ERRFILE>))
      {
        $HasErrEntries = 1;
        $Line =~ s/\s*$//;
        print $Sendmail "$Line\n";
      }
      close ERRFILE;
      if (! $HasErrEntries)
      {
        print $Sendmail "No test log and no error message";
      }
      else
      {
        push @FailureKeys, $Key;
      }
    }
  }

  # Print the log attachments
  foreach my $Key (@SortedKeys)
  {
    my $StepTask = $StepsTasks->GetItem($Key);
    my $TaskDir = $StepTask->GetTaskDir();

    print $Sendmail <<"EOF";

--$PART_BOUNDARY
Content-Type: text/plain; charset="UTF-8"
MIME-Version: 1.0
Content-Transfer-Encoding: 8bit
EOF
    print $Sendmail "Content-Disposition: attachment; filename=",
                    $StepTask->VM->Name, ".log\n\n";
    print $Sendmail "Not dumping logs in debug mode\n" if ($Debug);

    my $LogFiles = GetLogFileNames($TaskDir);
    my $LogName = $LogFiles->[0] || "log";
    my $PrintSeparator = !1;
    if (open LOGFILE, "<$TaskDir/$LogName")
    {
      my $Line;
      while (defined($Line = <LOGFILE>))
      {
        $Line =~ s/\s*$//;
        print $Sendmail "$Line\n" if (!$Debug);
        $PrintSeparator = 1;
      }
      close LOGFILE;
    }

    if (open ERRFILE, "<$TaskDir/err")
    {
      my $Line;
      while (defined($Line = <ERRFILE>))
      {
        if ($PrintSeparator)
        {
          print $Sendmail "\n" if (!$Debug);
          $PrintSeparator = !1;
        }
        $Line =~ s/\s*$//;
        print $Sendmail "$Line\n" if (!$Debug);
      }
      close ERRFILE;
    }
  }
  
  print $Sendmail "\n--$PART_BOUNDARY--\n";
  close($Sendmail);

  # This is all for jobs submitted from the website
  if (!defined $Job->Patch)
  {
    Debug("Not a mailing list patch -> all done.\n");
    return;
  }

  #
  # Build a job summary with only the new errors
  #

  my $Messages = "";
  foreach my $Key (@FailureKeys)
  {
    my $StepTask = $StepsTasks->GetItem($Key);
    my $TaskDir = $StepTask->GetTaskDir();

    my ($BotFailure, $MessagesFromErr) = CheckErrLog("$TaskDir/err");
    if ($BotFailure)
    {
      # TestBot errors are not the developer's fault and prevent us from doing
      # any meaningful analysis. So skip.
      Error "A TestBot error was found in $TaskDir/err\n";
      next;
    }

    my $MessagesFromLog = "";
    my $LogFiles = GetLogFileNames($TaskDir);
    my $LogName = $LogFiles->[0] || "log";
    if ($LogName =~ /\.report$/)
    {
      $StepTask->FileName =~ m/^(.*)_test(64)?\.exe$/;
      my ($BaseName, $Bits) = ($1, $2 || "32");
      my $LatestName = "$DataDir/latest/" . $StepTask->VM->Name . "_$Bits";
      my ($LatestBotFailure, $Dummy) = CheckErrLog("$LatestName.err");
      if (! $LatestBotFailure)
      {
        if (defined($StepTask->CmdLineArg))
        {
          # Filter out failures that happened in the full test suite:
          # the test suite is run against code which is already in Wine
          # so any failure it reported is not caused by this patch.
          $MessagesFromLog = CompareLogs("$LatestName.log", "$TaskDir/$LogName",
                                         $BaseName, $StepTask->CmdLineArg);
        }
      }
      else
      {
        Error "BotFailure found in ${LatestName}.err\n";
      }
    }
    elsif (open(my $LogFile, "<", "$TaskDir/$LogName"))
    {
      foreach my $Line (<$LogFile>)
      {
        my $Category = $LogName =~ /\.report$/ ?
                       GetReportLineCategory($Line) :
                       GetLogLineCategory($Line);
        $MessagesFromLog .= $Line if ($Category eq "error");
      }
      close($LogFile);
    }
    if ($MessagesFromErr || $MessagesFromLog)
    {
      $Messages .= "\n=== " . $StepTask->GetTitle() . " ===\n" .
                   $MessagesFromLog . $MessagesFromErr;
    }
  }

  #
  # Send a summary of the new errors to the mailing list
  #

  Debug("\n-------------------- Mailing list email --------------------\n");

  if ($Messages)
  {
    if ($Debug)
    {
      open($Sendmail, ">>&=", 1);
    }
    else
    {
      open($Sendmail, "|-", "/usr/sbin/sendmail -oi -t -odq");
    }
    print $Sendmail "From: $RobotEMail\n";
    print $Sendmail "To: $To\n";
    print $Sendmail "Cc: $WinePatchCc\n";
    print $Sendmail "Subject: Re: ", $Job->Patch->Subject, "\n";
    if ($Job->Patch->MessageId)
    {
      print $Sendmail "In-Reply-To: ", $Job->Patch->MessageId, "\n";
      print $Sendmail "References: ", $Job->Patch->MessageId, "\n";
    }
    print $Sendmail <<"EOF";

Hi,

While running your changed tests on Windows, I think I found new failures.
Being a bot and all I'm not very good at pattern recognition, so I might be
wrong, but could you please double-check?

Full results can be found at:
$JobURL

Your paranoid android.

EOF

    print $Sendmail $Messages;
    close($Sendmail);
  }
  else
  {
    Debug("Found no error to report to the mailing list\n");
  }

  #
  # Create a .testbot file for the patches website
  #

  my $Patch = $Job->Patch;
  if (defined $Patch->WebPatchId and -d "$DataDir/webpatches")
  {
    my $BaseName = "$DataDir/webpatches/" . $Patch->WebPatchId;
    Debug("\n-------------------- WebPatches report --------------------\n");
    Debug("-- $BaseName.testbot --\n");
    if (open(my $Result, ">", "$BaseName.testbot"))
    {
      # Only take into account new errors to decide whether the job was
      # successful or not.
      DebugTee($Result, "Status: ". ($Messages ? "Failed" : "OK") ."\n");
      DebugTee($Result, "Job-ID: ". $Job->Id ."\n");
      DebugTee($Result, "URL: $JobURL\n");

      foreach my $Key (@SortedKeys)
      {
        my $StepTask = $StepsTasks->GetItem($Key);
        my $TaskDir = $StepTask->GetTaskDir();

        print $Result "\n=== ", $StepTask->GetTitle(), " ===\n";

        my $LogFiles = GetLogFileNames($TaskDir);
        my $LogName = $LogFiles->[0] || "log";
        my $PrintSeparator = !1;
        if (open(my $logfile, "<", "$TaskDir/$LogName"))
        {
          my $Line;
          while (defined($Line = <$logfile>))
          {
            $Line =~ s/\s*$//;
            print $Result "$Line\n";
            $PrintSeparator = 1;
          }
          close($logfile);
        }
  
        if (open(my $errfile, "<", "$TaskDir/err"))
        {
          my $Line;
          while (defined($Line = <$errfile>))
          {
            if ($PrintSeparator)
            {
              print $Result "\n";
              $PrintSeparator = !1;
            }
            $Line =~ s/\s*$//;
            print $Result "$Line\n";
          }
          close($errfile);
        }
      }
      print $Result "--- END FULL_LOGS ---\n";
      close($Result);
    }
    else
    {
      Error "Job ". $Job->Id .": Unable to open '$BaseName.testbot' for writing: $!";
    }
  }
}


#
# Setup and command line processing
#

$ENV{PATH} = "/usr/bin:/bin";
delete $ENV{ENV};

my $Usage;
sub ValidateNumber($$)
{
  my ($Name, $Value) = @_;

  # Validate and untaint the value
  return $1 if ($Value =~ /^(\d+)$/);
  Error "$Value is not a valid $Name\n";
  $Usage = 2;
  return undef;
}

my ($JobId);
while (@ARGV)
{
  my $Arg = shift @ARGV;
  if ($Arg eq "--debug")
  {
    $Debug = 1;
  }
  elsif ($Arg eq "--log-only")
  {
    $LogOnly = 1;
  }
  elsif ($Arg =~ /^(?:-\?|-h|--help)$/)
  {
    $Usage = 0;
    last;
  }
  elsif ($Arg =~ /^-/)
  {
    Error "unknown option '$Arg'\n";
    $Usage = 2;
    last;
  }
  elsif (!defined $JobId)
  {
    $JobId = ValidateNumber('job id', $Arg);
  }
  else
  {
    Error "unexpected argument '$Arg'\n";
    $Usage = 2;
    last;
  }
}

# Check parameters
if (!defined $Usage)
{
  if (!defined $JobId)
  {
    Error "you must specify the job id\n";
    $Usage = 2;
  }
}
if (defined $Usage)
{
  if ($Usage)
  {
    Error "try '$Name0 --help' for more information\n";
    exit $Usage;
  }
  print "Usage: $Name0 [--debug] [--help] JOBID\n";
  print "\n";
  print "Analyze the job's logs and notifies the developer and the patches website.\n";
  print "\n";
  print "Where:\n";
  print "  JOBID      Id of the job to report on.\n";
  print "  --debug    More verbose messages for debugging.\n";
  print "  --log-only Only send error messages to the log instead of also printing them\n";
  print "             on stderr.\n";
  print "  --help     Shows this usage message.\n";
  exit 0;
}

my $Job = CreateJobs()->GetItem($JobId);
if (!defined $Job)
{
  Error "Job $JobId doesn't exist\n";
  exit 1;
}


#
# Analyze the log, notify the developer and the Patches website
#

SendLog($Job);

LogMsg "Log for job $JobId sent\n";

exit 0;
