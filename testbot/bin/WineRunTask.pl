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
use WineTestBot::LogUtils;
use WineTestBot::Engine::Notify;


#
# Logging and error handling helpers
#

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


#
# Task helpers
#

sub TakeScreenshot($$)
{
  my ($VM, $FileName) = @_;

  my $Domain = $VM->GetDomain();
  my ($ErrMessage, $ImageSize, $ImageBytes) = $Domain->CaptureScreenImage();
  if (!defined $ErrMessage)
  {
    my $OldUMask = umask(002);
    if (open(my $Screenshot, ">", $FileName))
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
my $VM = $Task->VM;
my $RptFileName = $Step->FileType .".report";


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
  if (open(my $ErrFile, ">>", "$TaskDir/err"))
  {
    print $ErrFile $ErrMessage;
    close($ErrFile);
  }
  else
  {
    Error "Unable to open 'err' for writing: $!\n";
  }
  umask($OldUMask);
}

sub WrapUpAndExit($;$$$)
{
  my ($Status, $TestFailures, $Retry, $TimedOut) = @_;
  my $NewVMStatus = $Status eq 'queued' ? 'offline' : 'dirty';
  my $VMResult = $Status eq "boterror" ? "boterror" :
                 $Status eq "queued" ? "error" :
                 $TimedOut ? "timeout" : "";

  Debug(Elapsed($Start), " Taking a screenshot\n");
  TakeScreenshot($VM, "$TaskDir/screenshot.png");

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

  if ($Step->Type eq 'suite' and $Status eq 'completed' and !$TimedOut)
  {
    # Keep the old report if the new one is missing
    if (-f "$TaskDir/$RptFileName" and !-z "$TaskDir/$RptFileName")
    {
      # Update the reference VM suite results for WineSendLog.pl
      my $LatestBaseName = join("", "$DataDir/latest/", $Task->VM->Name, "_",
                                $Step->FileType eq "exe64" ? "64" : "32");
      unlink("$LatestBaseName.log");
      link("$TaskDir/$RptFileName", "$LatestBaseName.log");
      unlink("$LatestBaseName.err");
      if (-f "$TaskDir/err" and !-z "$TaskDir/err")
      {
        link("$TaskDir/err", "$LatestBaseName.err");
      }
    }
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
  LogTaskError("BotError: $ErrMessage");

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
# Check the VM and Step
#

if ($VM->Type ne "win32" and $VM->Type ne "win64")
{
  FatalError("This is not a Windows VM! (" . $VM->Type . ")\n");
}
elsif (!$Debug and $VM->Status ne "running")
{
  FatalError("The VM is not ready for use (" . $VM->Status . ")\n");
}
elsif (!$VM->GetDomain()->IsPoweredOn())
{
  FatalError("The VM is not powered on\n");
}

if ($Step->FileType ne "exe32" and $Step->FileType ne "exe64")
{
  FatalError("Unexpected file type '". $Step->FileType ."' found\n");
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
  my $TestLauncher = "TestLauncher" . ($Step->FileType eq "exe64" ? "64" : "32") . ".exe";
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

  # If the user gave us an executable there is no telling
  # if it is going going to follow the Wine test standards.
  $IsWineTest = (defined $Step->PreviousNo and
                 $Job->Steps->GetItem($Step->PreviousNo)->FileType eq "patch");
}
elsif ($Step->Type eq "suite")
{
  $Keepalive = 60;
  $Script .= "$FileName ";
  my $Tag = lc($VM->Name);
  $Tag =~ s/^$TagPrefix//;
  $Tag =~ s/[^a-zA-Z0-9]/-/g;
  if ($VM->Type eq "win64")
  {
    $Tag .= "-" . ($Step->FileType eq "exe64" ? "64" : "32");
  }
  if (defined($WebHostName))
  {
    my $StepTask = 100 * $StepNo + $TaskNo;
    $Script .= "-u \"http://$WebHostName/JobDetails.pl?Key=$JobId&s$StepTask=1#k$StepTask\" ";
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
  $Script .= "-q -o $RptFileName -t $TagPrefix-$Tag -m \"$EMail\" -i \"$Info\"\r\n".
             "$FileName -q -s $RptFileName\r\n";
}
Debug(Elapsed($Start), " Sending the script: [$Script]\n");
if (!$TA->SendFileFromString($Script, "script.bat", $TestAgent::SENDFILE_EXE))
{
  FatalTAError($TA, "Could not send the task script to the VM");
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
Debug(Elapsed($Start), " Waiting for the script (", $Timeout, "s timeout)\n");
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
Debug(Elapsed($Start), " Retrieving the report file to '$RptFileName'\n");
if ($TA->GetFile($RptFileName, "$TaskDir/$RptFileName"))
{
  chmod 0664, "$TaskDir/$RptFileName";

  (my $LogFailures, my $LogErrors, $TimedOut) = ParseWineTestReport("$TaskDir/$RptFileName", $IsWineTest, $Step->Type eq "suite", $TaskTimedOut);
  if (!defined $LogFailures and @$LogErrors == 1)
  {
    # Could not open the file
    $NewStatus = 'boterror';
    Error "Unable to open '$RptFileName' for reading: $!\n";
    LogTaskError("Unable to open '$RptFileName' for reading: $!\n");
  }
  else
  {
    # $LogFailures can legitimately be undefined in case of a timeout
    $TaskFailures += $LogFailures || 0;
    foreach my $Error (@$LogErrors)
    {
      LogTaskError("$Error\n");
    }
  }
}
elsif (!defined $TAError)
{
  $TAError = "An error occurred while retrieving $RptFileName: ". $TA->GetLastError();
}
$TA->Disconnect();

FatalTAError(undef, $TAError, $PossibleCrash) if (defined $TAError);


#
# Wrap up
#

WrapUpAndExit($NewStatus, $TaskFailures, undef, $TaskTimedOut || $TimedOut);
