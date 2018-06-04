#!/usr/bin/perl -Tw
# -*- Mode: Perl; perl-indent-level: 2; indent-tabs-mode: nil -*-
#
# Sends and runs the tasks in the Windows test VMs.
#
# Copyright 2009 Ge van Geldorp
# Copyright 2013-2016 Francois Gouget
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


use WineTestBot::Config;
use WineTestBot::Jobs;
use WineTestBot::VMs;
use WineTestBot::Log;
use WineTestBot::Engine::Notify;


my $Debug;
sub Debug(@)
{
  print STDERR @_ if ($Debug);
}

my $LogOnly;
sub Error(@)
{
  print STDERR "$Name0:error: ", @_ if (!$LogOnly);
  LogMsg @_;
}

sub TakeScreenshot($$)
{
  my ($VM, $FullScreenshotFileName) = @_;

  my $Domain = $VM->GetDomain();
  my ($ErrMessage, $ImageSize, $ImageBytes) = $Domain->CaptureScreenImage();
  if (!defined $ErrMessage)
  {
    my $OldUMask = umask(002);
    if (open(my $Screenshot, ">", $FullScreenshotFileName))
    {
      print $Screenshot $ImageBytes;
      close($Screenshot);
    }
    else
    {
      Error "Could not open the screenshot file for writing: $!\n";
    }
    umask($OldUMask);
  }
  elsif ($Domain->IsPoweredOn())
  {
    Error "Could not capture a screenshot: $ErrMessage\n";
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

my ($JobId, $StepNo, $TaskNo);
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
  elsif (!defined $StepNo)
  {
    $StepNo = ValidateNumber('step number', $Arg);
  }
  elsif (!defined $TaskNo)
  {
    $TaskNo = ValidateNumber('task number', $Arg);
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
  if (!defined $JobId || !defined $StepNo || !defined $TaskNo)
  {
    Error "you must specify the job id, step number and task number\n";
    $Usage = 2;
  }
}
if (defined $Usage)
{
    print "Usage: $Name0 [--debug] [--log-only] [--help] JobId StepNo TaskNo\n";
    exit $Usage;
}

my $Job = CreateJobs()->GetItem($JobId);
if (!defined $Job)
{
  Error "Job $JobId does not exist\n";
  exit 1;
}
my $Step = $Job->Steps->GetItem($StepNo);
if (!defined $Step)
{
  Error "Step $StepNo of job $JobId does not exist\n";
  exit 1;
}
my $Task = $Step->Tasks->GetItem($TaskNo);
if (!defined $Task)
{
  Error "Step $StepNo task $TaskNo of job $JobId does not exist\n";
  exit 1;
}

my $OldUMask = umask(002);
my $TaskDir = $Task->CreateDir();
umask($OldUMask);
my $FullLogFileName = "$TaskDir/log";
my $FullErrFileName = "$TaskDir/err";
my $FullScreenshotFileName = "$TaskDir/screenshot.png";

my $VM = $Task->VM;
my $RptFileName = $VM->Name . ".rpt";

my $Start = Time();
LogMsg "Task $JobId/$StepNo/$TaskNo started\n";


#
# Error handling helpers
#

sub LogTaskError($)
{
  my ($ErrMessage) = @_;
  Debug("$Name0:error: ", $ErrMessage);

  my $OldUMask = umask(002);
  if (open(my $ErrFile, ">>", $FullErrFileName))
  {
    print $ErrFile $ErrMessage;
    close($ErrFile);
  }
  else
  {
    Error "Unable to open '$FullErrFileName' for writing: $!\n";
  }
  umask($OldUMask);
}

sub WrapUpAndExit($;$$$)
{
  my ($Status, $TestFailures, $Retry, $Timeout) = @_;
  my $NewVMStatus = $Status eq 'queued' ? 'offline' : 'dirty';
  my $VMResult = $Status eq "boterror" ? "boterror" :
                 $Status eq "queued" ? "error" :
                 $Timeout ? "timeout" : "";

  Debug(Elapsed($Start), " Taking a screenshot\n");
  TakeScreenshot($VM, $FullScreenshotFileName);

  my $Tries = $Task->TestFailures || 0;
  if ($Retry)
  {
    # This may be a transient error (e.g. a network glitch)
    # so retry a few times to improve robustness
    $Tries++;
    if ($Task->CanRetry())
    {
      $Status = 'queued';
      $TestFailures = $Tries;
    }
    else
    {
      LogTaskError("Giving up after $Tries run(s)\n");
    }
  }
  elsif ($Tries >= 1)
  {
    LogTaskError("The previous $Tries run(s) terminated abnormally\n");
  }

  # Record result details that may be lost or overwritten by a later run
  if ($VMResult)
  {
    $VMResult .= " $Tries $MaxTaskTries" if ($Retry);
    $VM->RecordResult(undef, $VMResult);
  }

  # Update the Task and Job
  $Task->Status($Status);
  $Task->TestFailures($TestFailures);
  if ($Status eq 'queued')
  {
    $Task->Started(undef);
    $Task->Ended(undef);
    # Leave the Task files around so they can be seen until the next run
  }
  else
  {
    $Task->Ended(time());
  }
  $Task->Save();
  $Job->UpdateStatus();

  # Get the up-to-date VM status and update it if nobody else changed it
  $VM = CreateVMs()->GetItem($VM->GetKey());
  if ($VM->Status eq 'running')
  {
    $VM->Status($NewVMStatus);
    $VM->ChildDeadline(undef);
    $VM->ChildPid(undef);
    $VM->Save();
  }

  if ($Status eq 'completed' and $Step->Type eq 'suite')
  {
    # Update the reference VM suite results for WineSendLog.pl
    my $LatestBaseName = join("", "$DataDir/latest/", $Task->VM->Name, "_",
                              $Step->FileType eq "exe64" ? "64" : "32");
    unlink("$LatestBaseName.log");
    link($FullLogFileName, "$LatestBaseName.log") if (-f $FullLogFileName);
    unlink("$LatestBaseName.err");
    link($FullErrFileName, "$LatestBaseName.err") if (-f $FullErrFileName);
  }

  my $Result = $VM->Name .": ". $VM->Status ." Status: $Status Failures: ". (defined $TestFailures ? $TestFailures : "unset");
  LogMsg "Task $JobId/$StepNo/$TaskNo done ($Result)\n";
  Debug(Elapsed($Start), " Done. $Result\n");
  exit($Status eq 'completed' ? 0 : 1);
}

sub FatalError($;$)
{
  my ($ErrMessage, $Retry) = @_;

  LogMsg "$JobId/$StepNo/$TaskNo $ErrMessage";
  LogTaskError($ErrMessage);

  WrapUpAndExit('boterror', undef, $Retry);
}

sub FatalTAError($$;$)
{
  my ($TA, $ErrMessage, $PossibleCrash) = @_;
  $ErrMessage .= ": ". $TA->GetLastError() if (defined $TA);

  # A TestAgent operation failed, see if the VM is still accessible
  my $IsPoweredOn = $VM->GetDomain()->IsPoweredOn();
  if (!defined $IsPoweredOn)
  {
    # The VM host is not accessible anymore so mark the VM as offline and
    # requeue the task. This does not count towards the task's tries limit
    # since neither the VM nor the task are at fault.
    Error("$ErrMessage\n");
    WrapUpAndExit('queued');
  }

  my $Retry;
  if ($IsPoweredOn)
  {
    LogMsg("$ErrMessage\n");
    LogTaskError("$ErrMessage\n");
    $ErrMessage = "The test VM has crashed, rebooted or lost connectivity (or the TestAgent server died)\n";
    # Retry in case it was a temporary network glitch
    $Retry = 1;
  }
  else
  {
    # Ignore the TestAgent error, it's irrelevant
    $ErrMessage = "The test VM is powered off! Did the test shut it down?\n";
  }
  if ($PossibleCrash and !$Task->CanRetry())
  {
    # The test did it!
    LogTaskError($ErrMessage);
    WrapUpAndExit('completed', 1);
  }
  FatalError($ErrMessage, $Retry);
}


#
# Check the VM
#

if (!$Debug and $VM->Status ne "running")
{
  FatalError("The VM is not ready for use (" . $VM->Status . ")\n");
}
elsif ($Debug and !$VM->GetDomain()->IsPoweredOn())
{
  FatalError("The VM is not powered on\n");
}


#
# Setup the VM
#

my $TA = $VM->GetAgent();
Debug(Elapsed($Start), " Setting the time\n");
if (!$TA->SetTime())
{
  # Not a fatal error. Try the next port in case the VM runs a privileged
  # TestAgentd daemon there.
  my $PrivilegedTA = $VM->GetAgent(1);
  if (!$PrivilegedTA->SetTime())
  {
    LogTaskError("Unable to set the VM system time: ". $PrivilegedTA->GetLastError() .". Maybe the TestAgentd process is missing the required privileges.\n");
    $PrivilegedTA->Disconnect();
  }
}

my $FileType = $Step->FileType;
if ($FileType ne "exe32" && $FileType ne "exe64")
{
  FatalError("Unexpected file type $FileType found\n");
}
my $FileName = $Step->FileName;
Debug(Elapsed($Start), " Sending '". $Step->GetFullFileName() ."'\n");
if (!$TA->SendFile($Step->GetFullFileName(), $FileName, 0))
{
  FatalTAError($TA, "Could not copy the test executable to the VM");
}

my $Keepalive;
my $Timeout = $Task->Timeout;
my $Script = "\@echo off\r\nset WINETEST_DEBUG=" . $Step->DebugLevel .
             "\r\n";
if ($Step->ReportSuccessfulTests)
{
  $Script .= "set WINETEST_REPORT_SUCCESS=1\r\n";
}
my $IsWineTest = 1;
if ($Step->Type eq "single")
{
  my $TestLauncher = "TestLauncher" . ($FileType eq "exe64" ? "64" : "32") . ".exe";
  Debug(Elapsed($Start), " Sending 'latest/$TestLauncher'\n");
  if (!$TA->SendFile("$DataDir/latest/$TestLauncher", $TestLauncher, 0))
  {
    FatalTAError($TA, "Could not copy TestLauncher to the VM");
  }

  $Script .= "$TestLauncher -t $Timeout $FileName ";
  # Add 1 second to the timeout so the client-side Wait() does not time out
  # right before $TestLauncher does.
  $Timeout += 1;
  $Keepalive = 20;
  my $CmdLineArg = $Task->CmdLineArg;
  if ($CmdLineArg)
  {
    $Script .= "$CmdLineArg ";
  }
  $Script .= "> $RptFileName\r\n";

  # If StepNo is 1 then the user gave us an executable. Then there is no
  # telling if it's going to follow the Wine test standards.
  $IsWineTest = ($StepNo != 1);
}
elsif ($Step->Type eq "suite")
{
  $Keepalive = 60;
  $Script .= "$FileName ";
  my $Tag = lc($TagPrefix) . "-" . lc($VM->Name);
  $Tag =~ s/[^a-zA-Z0-9]/-/g;
  if ($VM->Type eq "win64")
  {
    $Tag .= "-" . ($FileType eq "exe64" ? "64" : "32");
  }
  if (defined($WebHostName))
  {
    my $StepTask = 100 * $StepNo + $TaskNo;
    $Script .= '-u "http://' . $WebHostName . "/JobDetails.pl?Key=" .
               $JobId . "&scrshot_" . $StepTask . "=1#k" . $StepTask . '" ';
  }
  my $Info = $VM->Description ? $VM->Description : "";
  if ($VM->Details)
  {
      $Info .= ": " if ($Info ne "");
      $Info .=  $VM->Details;
  }
  # Escape the arguments for cmd's command interpreter
  my $EMail = $AdminEMail;
  $EMail =~ s/"/\\"/g;
  $EMail =~ s/%/%%/g;
  $EMail =~ s/%/%%/g;
  $Info =~ s/"/\\"/g;
  $Info =~ s/%/%%/g;
  $Info =~ s/%/%%/g;
  $Script .= "-q -o $RptFileName -t $Tag -m \"$EMail\" -i \"$Info\"\r\n" .
             "$FileName -q -s $RptFileName\r\n";
}
Debug(Elapsed($Start), " Sending the script: [$Script]\n");
if (!$TA->SendFileFromString($Script, "script.bat", $TestAgent::SENDFILE_EXE))
{
  FatalTAError($TA, "Could not send the script to the VM");
}


#
# Run the test
#

Debug(Elapsed($Start), " Starting the script\n");
my $Pid = $TA->Run(["./script.bat"], 0);
if (!$Pid)
{
  FatalTAError($TA, "Failed to start the test");
}


#
# From that point on we want to at least try to grab the test
# log and a screenshot before giving up
#

my $NewStatus = 'completed';
my ($TaskFailures, $TaskTimedOut, $TAError, $PossibleCrash);
Debug(Elapsed($Start), " Waiting for the script (", $Task->Timeout, "s timeout)\n");
if (!defined $TA->Wait($Pid, $Timeout, $Keepalive))
{
  my $ErrMessage = $TA->GetLastError();
  if ($ErrMessage =~ /timed out waiting for the child process/)
  {
    LogTaskError("The task timed out\n");
    $TaskFailures = 1;
    $TaskTimedOut = 1;
  }
  else
  {
    $PossibleCrash = 1;
    $TAError = "An error occurred while waiting for the test to complete: $ErrMessage";
  }
}

my $TimedOut;
Debug(Elapsed($Start), " Retrieving the report file to '$FullLogFileName'\n");
if ($TA->GetFile($RptFileName, $FullLogFileName))
{
  chmod 0664, $FullLogFileName;
  if (open(my $LogFile, "<", $FullLogFileName))
  {
    # There is more than one test unit when running the full test suite so keep
    # track of the current one. Note that for the TestBot we don't count or
    # complain about misplaced skips.
    my ($CurrentDll, $CurrentUnit) = ("", "");
    my $UnitSize = 0;
    my ($LineFailures, $LineTodos, $LineSkips) = (0, 0, 0);
    my ($SummaryFailures, $SummaryTodos, $SummarySkips) = (0, 0, 0);
    my ($CurrentIsBroken, %CurrentPids, $CurrentRc, $LogFailures);

    sub CheckUnit($$)
    {
      my ($Unit, $Type) = @_;
      if ($Unit eq $CurrentUnit or $CurrentUnit eq "")
      {
        $IsWineTest = 1;
      }
      # To avoid issuing many duplicate errors,
      # only report the first misplaced message.
      elsif ($IsWineTest and !$CurrentIsBroken)
      {
        LogTaskError("$CurrentDll:$CurrentUnit contains a misplaced $Type message for $Unit\n");
        $LogFailures++;
        $CurrentIsBroken = 1;
      }
    }

    sub CheckSummaryCounter($$$)
    {
      my ($Count, $SCount, $Type) = @_;

      if ($Count != 0 and $SCount == 0)
      {
        LogTaskError("$CurrentDll:$CurrentUnit has unaccounted for $Type messages\n");
        $LogFailures++;
      }
      elsif ($Count == 0 and $SCount != 0)
      {
        LogTaskError("$CurrentDll:$CurrentUnit is missing some $Type messages\n");
        $LogFailures++;
      }
    }

    sub CloseTestUnit($)
    {
      my ($Last) = @_;

      # Verify the summary lines
      if (!$CurrentIsBroken)
      {
        CheckSummaryCounter($LineFailures, $SummaryFailures, "failure");
        CheckSummaryCounter($LineTodos, $SummaryTodos, "todo");
        CheckSummaryCounter($LineSkips, $SummarySkips, "skip");
      }

      # Note that the summary lines may count some failures twice
      # so only use them as a fallback.
      $LineFailures ||= $SummaryFailures;

      if ($UnitSize > $MaxUnitSize)
      {
        LogTaskError("$CurrentDll:$CurrentUnit prints too much data ($UnitSize bytes)\n");
        $LogFailures++;
      }
      if (!$CurrentIsBroken and defined $CurrentRc)
      {
        # Check the exit code, particularly against failures reported
        # after the 'done' line (e.g. by subprocesses).
        if ($LineFailures != 0 and $CurrentRc == 0)
        {
          LogTaskError("$CurrentDll:$CurrentUnit returned success despite having failures\n");
          $LogFailures++;
        }
        elsif (!$IsWineTest and $CurrentRc != 0)
        {
          LogTaskError("The test returned a non-zero exit code\n");
          $LogFailures++;
        }
        elsif ($IsWineTest and $LineFailures == 0 and $CurrentRc != 0)
        {
          LogTaskError("$CurrentDll:$CurrentUnit returned a non-zero exit code despite reporting no failures\n");
          $LogFailures++;
        }
      }
      # For executables TestLauncher's done line may not be recognizable.
      elsif ($IsWineTest and !defined $CurrentRc)
      {
        if (!$Last)
        {
          LogTaskError("$CurrentDll:$CurrentUnit has no done line (or it is garbled)\n");
        }
        elsif ($Last and !$TaskTimedOut)
        {
          LogTaskError("The report seems to have been truncated\n");
        }
        $LogFailures++;
      }

      $LogFailures += $LineFailures;

      $CurrentDll = $CurrentUnit = "";
      $UnitSize = 0;
      $LineFailures = $LineTodos = $LineSkips = 0;
      $SummaryFailures = $SummaryTodos = $SummarySkips = 0;
      $CurrentIsBroken = 0;
      $CurrentRc = undef;
      %CurrentPids = ();
    }

    foreach my $Line (<$LogFile>)
    {
      $UnitSize += length($Line);
      if ($Line =~ m%^([_.a-z0-9-]+):([_a-z0-9]*) (start|skipped) (?:-|[/_.a-z0-9]+) (?:-|[.0-9a-f]+)\r?$%)
      {
        my ($Dll, $Unit, $Type) = ($1, $2, $3);

        # Close the previous test unit
        CloseTestUnit(0) if ($CurrentDll ne "");

        ($CurrentDll, $CurrentUnit) = ($Dll, $Unit);

        # Recognize skipped messages in case we need to skip tests in the VMs
        $CurrentRc = 0 if ($Type eq "skipped");
      }
      elsif ($Line =~ /^([_a-z0-9]+)\.c:\d+: Test (?:failed|succeeded inside todo block): / or
             ($CurrentUnit ne "" and
              $Line =~ /($CurrentUnit)\.c:\d+: Test (?:failed|succeeded inside todo block): /))
      {
        CheckUnit($1, "failure");
        $LineFailures++;
      }
      elsif ($Line =~ /^([_a-z0-9]+)\.c:\d+: Test marked todo: / or
             ($CurrentUnit ne "" and
              $Line =~ /($CurrentUnit)\.c:\d+: Test marked todo: /))
      {
        CheckUnit($1, "todo");
        $LineTodos++;
      }
      # TestLauncher's skip message is quite broken
      elsif ($Line =~ /^([_a-z0-9]+)(?:\.c)?:\d+:? Tests? skipped: / or
             ($CurrentUnit ne "" and
              $Line =~ /($CurrentUnit)(?:\.c)?:\d+:? Tests? skipped: /))
      {
        my $Unit = $1;
        # Don't complain and don't count misplaced skips. Only complain if they
        # are misreported (see CloseTestUnit). Also TestLauncher uses the wrong
        # name in its skip message when skipping tests.
        if ($Unit eq $CurrentUnit or $CurrentUnit eq "" or $Unit eq $CurrentDll)
        {
          $LineSkips++;
        }
      }
      elsif ($Line =~ /^Fatal: test '([_a-z0-9]+)' does not exist/)
      {
        # This also replaces a test summary line.
        $CurrentPids{0} = 1;
        $SummaryFailures++;
        $IsWineTest = 1;

        $LineFailures++;
      }
      elsif ($Line =~ /^(?:([0-9a-f]+):)?([_.a-z0-9]+): unhandled exception [0-9a-fA-F]{8} at / or
             ($CurrentUnit ne "" and
              $Line =~ /(?:([0-9a-f]+):)?($CurrentUnit): unhandled exception [0-9a-fA-F]{8} at /))
      {
        my ($Pid, $Unit) = ($1, $2);

        if ($Unit eq $CurrentUnit)
        {
          # This also replaces a test summary line.
          $CurrentPids{$Pid || 0} = 1;
          $SummaryFailures++;
        }
        CheckUnit($Unit, "unhandled exception");
        $LineFailures++;
      }
      elsif ($Line =~ /^(?:([0-9a-f]+):)?([_a-z0-9]+): \d+ tests? executed \((\d+) marked as todo, (\d+) failures?\), (\d+) skipped\./ or
             ($CurrentUnit ne "" and
              $Line =~ /(?:([0-9a-f]+):)?($CurrentUnit): \d+ tests? executed \((\d+) marked as todo, (\d+) failures?\), (\d+) skipped\./))
      {
        my ($Pid, $Unit, $Todos, $Failures, $Skips) = ($1, $2, $3, $4, $5);

        # Dlls that have only one test unit will run it even if there is
        # no argument. Also TestLauncher uses the wrong name in its test
        # summary line when skipping tests.
        if ($Unit eq $CurrentUnit or $CurrentUnit eq "" or $Unit eq $CurrentDll)
        {
          # There may be more than one summary line due to child processes
          $CurrentPids{$Pid || 0} = 1;
          $SummaryFailures += $Failures;
          $SummaryTodos += $Todos;
          $SummarySkips += $Skips;
          $IsWineTest = 1;
        }
        else
        {
          CheckUnit($Unit, "test summary") if ($Todos or $Failures);
        }
      }
      elsif ($Line =~ /^([_.a-z0-9-]+):([_a-z0-9]*)(?::([0-9a-f]+))? done \((-?\d+)\)(?:\r?$| in)/ or
             ($CurrentDll ne "" and
              $Line =~ /(\Q$CurrentDll\E):([_a-z0-9]*)(?::([0-9a-f]+))? done \((-?\d+)\)(?:\r?$| in)/))
      {
        my ($Dll, $Unit, $Pid, $Rc) = ($1, $2, $3, $4);

        if ($IsWineTest and ($Dll ne $CurrentDll or $Unit ne $CurrentUnit))
        {
          # First close the current test unit taking into account
          # it may have been polluted by the new one.
          $LogFailures++;
          $CurrentIsBroken = 1;
          CloseTestUnit(0);

          # Then switch to the new one, warning it's missing a start line,
          # and that its results may be inconsistent.
          ($CurrentDll, $CurrentUnit) = ($Dll, $Unit);
          LogTaskError("$Dll:$Unit had no start line (or it is garbled)\n");
          $CurrentIsBroken = 1;
        }

        if ($Rc == 258)
        {
          # The done line will already be shown as a timeout (see JobDetails)
          # so record the failure but don't add an error message.
          $LogFailures++;
          $CurrentIsBroken = 1;
          $TimedOut = ($Step->Type ne "suite");
        }
        elsif ((!$Pid and !%CurrentPids) or
               ($Pid and !$CurrentPids{$Pid} and !$CurrentPids{0}))
        {
          # The main summary line is missing
          if ($Rc & 0xc0000000)
          {
            LogTaskError(sprintf("%s:%s crashed (%08x)\n", $Dll, $Unit, $Rc & 0xffffffff));
            $LogFailures++;
            $CurrentIsBroken = 1;
          }
          elsif ($IsWineTest and !$CurrentIsBroken)
          {
            LogTaskError("$Dll:$Unit has no test summary line (early exit of the main process?)\n");
            $LogFailures++;
          }
        }
        elsif ($Rc & 0xc0000000)
        {
          # We know the crash happened in the main process which means we got
          # an "unhandled exception" message. So there is no need to add an
          # extra message or to increment the failure count. Still note that
          # there may be inconsistencies (e.g. unreported todos or skips).
          $CurrentIsBroken = 1;
        }
        $CurrentRc = $Rc;
      }
    }
    $CurrentIsBroken = 1 if ($TaskTimedOut);
    CloseTestUnit(1);
    close($LogFile);

    # $LogFailures can legitimately be undefined in case of a timeout
    $TaskFailures += $LogFailures || 0;
  }
  else
  {
    $NewStatus = 'boterror';
    Error "Unable to open '$FullLogFileName' for reading: $!\n";
    LogTaskError("Unable to open the log file for reading: $!\n");
  }
}
elsif (!defined $TAError)
{
  $TAError = "An error occurred while retrieving the test report: ". $TA->GetLastError();
}
$TA->Disconnect();

FatalTAError(undef, $TAError, $PossibleCrash) if (defined $TAError);


#
# Wrap up
#

WrapUpAndExit($NewStatus, $TaskFailures, undef, $TaskTimedOut || $TimedOut);
