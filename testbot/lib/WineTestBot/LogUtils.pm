# -*- Mode: Perl; perl-indent-level: 2; indent-tabs-mode: nil -*-
# Copyright 2018 Francois Gouget
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

package WineTestBot::LogUtils;

=head1 NAME

WineTestBot::LogUtils - Provides functions to parse task logs

=cut


use Exporter 'import';
our @EXPORT = qw(GetLogFileNames GetLogLabel GetLogLineCategory
                 ParseTaskLog ParseWineTestReport);

use File::Basename;

use WineTestBot::Config; # For $MaxUnitSize


#
# Task log parser
#

=pod
=over 12

=item C<ParseTaskLog()>

Returns ok if the task was successful and an error code otherwise.

=back
=cut

sub ParseTaskLog($$)
{
  my ($FileName, $ResultPrefix) = @_;

  if (open(my $LogFile, "<", $FileName))
  {
    my $Result;
    foreach my $Line (<$LogFile>)
    {
      chomp $Line;
      if ($Line =~ /^$ResultPrefix: ok$/)
      {
        $Result ||= "ok";
      }
      elsif ($Line =~ /^$ResultPrefix: Patch failed to apply$/)
      {
        $Result = "badpatch";
        last; # Should be the last and most specific message
      }
      elsif ($Line =~ /^$ResultPrefix: /)
      {
        $Result = "failed";
      }
    }
    close($LogFile);
    return $Result || "missing";
  }
  return "nolog:Unable to open the task log for reading: $!";
}


#
# WineTest report parser
#

sub _NewCurrentUnit($$)
{
  my ($Dll, $Unit) = @_;

  return {
    # There is more than one test unit when running the full test suite so keep
    # track of the current one. Note that for the TestBot we don't count or
    # complain about misplaced skips.
    Dll => $Dll,
    Unit => $Unit,
    UnitSize => 0,
    LineFailures => 0,
    LineTodos => 0,
    LineSkips => 0,
    SummaryFailures => 0,
    SummaryTodos => 0,
    SummarySkips => 0,
    IsBroken => 0,
    Rc => undef,
    Pids => {},
  };
}

sub _AddError($$;$)
{
  my ($Parser, $Error, $Cur) = @_;

  $Error = "$Cur->{Dll}:$Cur->{Unit} $Error" if (defined $Cur);
  push @{$Parser->{Errors}}, $Error;
  $Parser->{Failures}++;
}

sub _CheckUnit($$$$)
{
  my ($Parser, $Cur, $Unit, $Type) = @_;

  if ($Unit eq $Cur->{Unit} or $Cur->{Unit} eq "")
  {
    $Parser->{IsWineTest} = 1;
  }
  # To avoid issuing many duplicate errors,
  # only report the first misplaced message.
  elsif ($Parser->{IsWineTest} and !$Cur->{IsBroken})
  {
    _AddError($Parser, "contains a misplaced $Type message for $Unit", $Cur);
    $Cur->{IsBroken} = 1;
  }
}

sub _CheckSummaryCounter($$$$)
{
  my ($Parser, $Cur, $Field, $Type) = @_;

  if ($Cur->{"Line$Field"} != 0 and $Cur->{"Summary$Field"} == 0)
  {
    _AddError($Parser, "has unaccounted for $Type messages", $Cur);
  }
  elsif ($Cur->{"Line$Field"} == 0 and $Cur->{"Summary$Field"} != 0)
  {
    _AddError($Parser, "is missing some $Type messages", $Cur);
  }
}

sub _CloseTestUnit($$$)
{
  my ($Parser, $Cur, $Last) = @_;

  # Verify the summary lines
  if (!$Cur->{IsBroken})
  {
    _CheckSummaryCounter($Parser, $Cur, "Failures", "failure");
    _CheckSummaryCounter($Parser, $Cur, "Todos", "todo");
    _CheckSummaryCounter($Parser, $Cur, "Skips", "skip");
  }

  # Note that the summary lines may count some failures twice
  # so only use them as a fallback.
  $Cur->{LineFailures} ||= $Cur->{SummaryFailures};

  if ($Cur->{UnitSize} > $MaxUnitSize)
  {
    _AddError($Parser, "prints too much data ($Cur->{UnitSize} bytes)", $Cur);
  }
  if (!$Cur->{IsBroken} and defined $Cur->{Rc})
  {
    # Check the exit code, particularly against failures reported
    # after the 'done' line (e.g. by subprocesses).
    if ($Cur->{LineFailures} != 0 and $Cur->{Rc} == 0)
    {
      _AddError($Parser, "returned success despite having failures", $Cur);
    }
    elsif (!$Parser->{IsWineTest} and $Cur->{Rc} != 0)
    {
      _AddError($Parser, "The test returned a non-zero exit code");
    }
    elsif ($Parser->{IsWineTest} and $Cur->{LineFailures} == 0 and $Cur->{Rc} != 0)
    {
      _AddError($Parser, "returned a non-zero exit code despite reporting no failures", $Cur);
    }
  }
  # For executables TestLauncher's done line may not be recognizable.
  elsif ($Parser->{IsWineTest} and !defined $Cur->{Rc})
  {
    if (!$Last)
    {
      _AddError($Parser, "has no done line (or it is garbled)", $Cur);
    }
    elsif ($Last and !$Parser->{TaskTimedOut})
    {
      _AddError($Parser, "The report seems to have been truncated");
    }
  }

  $Parser->{Failures} += $Cur->{LineFailures};
}

=pod
=over 12

=item C<ParseWineTestReport()>

Parses a Wine test report and returns the number of failures and extra errors,
a list of extra errors, and whether the test timed out.

=back
=cut

sub ParseWineTestReport($$$$)
{
  my ($FileName, $IsWineTest, $IsSuite, $TaskTimedOut) = @_;

  my $LogFile;
  if (!open($LogFile, "<", $FileName))
  {
    my $BaseName = basename($FileName);
    return (undef, ["Unable to open '$BaseName' for reading: $!"], undef);
  }

  my $Parser = {
    IsWineTest => $IsWineTest,
    IsSuite => $IsSuite,
    TaskTimedOut => $TaskTimedOut,

    TimedOut => undef,
    Failures => undef,
    Errors => [],
  };

  my $Cur = _NewCurrentUnit("", "");
  foreach my $Line (<$LogFile>)
  {
    $Cur->{UnitSize} += length($Line);
    if ($Line =~ m%^([_.a-z0-9-]+):([_a-z0-9]*) (start|skipped) (?:-|[/_.a-z0-9]+) (?:-|[.0-9a-f]+)\r?$%)
    {
      my ($Dll, $Unit, $Type) = ($1, $2, $3);

      # Close the previous test unit
      _CloseTestUnit($Parser, $Cur, 0) if ($Cur->{Dll} ne "");
      $Cur = _NewCurrentUnit($Dll, $Unit);

      # Recognize skipped messages in case we need to skip tests in the VMs
      $Cur->{Rc} = 0 if ($Type eq "skipped");
    }
    elsif ($Line =~ /^([_a-z0-9]+)\.c:\d+: Test (?:failed|succeeded inside todo block): / or
           ($Cur->{Unit} ne "" and
            $Line =~ /($Cur->{Unit})\.c:\d+: Test (?:failed|succeeded inside todo block): /))
    {
      _CheckUnit($Parser, $Cur, $1, "failure");
      $Cur->{LineFailures}++;
    }
    elsif ($Line =~ /^([_a-z0-9]+)\.c:\d+: Test marked todo: / or
           ($Cur->{Unit} ne "" and
            $Line =~ /($Cur->{Unit})\.c:\d+: Test marked todo: /))
    {
      _CheckUnit($Parser, $Cur, $1, "todo");
      $Cur->{LineTodos}++;
    }
    # TestLauncher's skip message is quite broken
    elsif ($Line =~ /^([_a-z0-9]+)(?:\.c)?:\d+:? Tests? skipped: / or
           ($Cur->{Unit} ne "" and
            $Line =~ /($Cur->{Unit})(?:\.c)?:\d+:? Tests? skipped: /))
    {
      my $Unit = $1;
      # Don't complain and don't count misplaced skips. Only complain if they
      # are misreported (see _CloseTestUnit). Also TestLauncher uses the wrong
      # name in its skip message when skipping tests.
      if ($Unit eq $Cur->{Unit} or $Cur->{Unit} eq "" or $Unit eq $Cur->{Dll})
      {
        $Cur->{LineSkips}++;
      }
    }
    elsif ($Line =~ /^Fatal: test '([_a-z0-9]+)' does not exist/)
    {
      # This also replaces a test summary line.
      $Cur->{Pids}->{0} = 1;
      $Cur->{SummaryFailures}++;
      $Parser->{IsWineTest} = 1;

      $Cur->{LineFailures}++;
    }
    elsif ($Line =~ /^(?:([0-9a-f]+):)?([_.a-z0-9]+): unhandled exception [0-9a-fA-F]{8} at / or
           ($Cur->{Unit} ne "" and
            $Line =~ /(?:([0-9a-f]+):)?($Cur->{Unit}): unhandled exception [0-9a-fA-F]{8} at /))
    {
      my ($Pid, $Unit) = ($1, $2);

      if ($Unit eq $Cur->{Unit})
      {
        # This also replaces a test summary line.
        $Cur->{Pids}->{$Pid || 0} = 1;
        $Cur->{SummaryFailures}++;
      }
      _CheckUnit($Parser, $Cur, $Unit, "unhandled exception");
      $Cur->{LineFailures}++;
    }
    elsif ($Line =~ /^(?:([0-9a-f]+):)?([_a-z0-9]+): \d+ tests? executed \((\d+) marked as todo, (\d+) failures?\), (\d+) skipped\./ or
           ($Cur->{Unit} ne "" and
            $Line =~ /(?:([0-9a-f]+):)?($Cur->{Unit}): \d+ tests? executed \((\d+) marked as todo, (\d+) failures?\), (\d+) skipped\./))
    {
      my ($Pid, $Unit, $Todos, $Failures, $Skips) = ($1, $2, $3, $4, $5);

      # Dlls that have only one test unit will run it even if there is
      # no argument. Also TestLauncher uses the wrong name in its test
      # summary line when skipping tests.
      if ($Unit eq $Cur->{Unit} or $Cur->{Unit} eq "" or $Unit eq $Cur->{Dll})
      {
        # There may be more than one summary line due to child processes
        $Cur->{Pids}->{$Pid || 0} = 1;
        $Cur->{SummaryFailures} += $Failures;
        $Cur->{SummaryTodos} += $Todos;
        $Cur->{SummarySkips} += $Skips;
        $Parser->{IsWineTest} = 1;
      }
      else
      {
        _CheckUnit($Parser, $Cur, $Unit, "test summary") if ($Todos or $Failures);
      }
    }
    elsif ($Line =~ /^([_.a-z0-9-]+):([_a-z0-9]*)(?::([0-9a-f]+))? done \((-?\d+)\)(?:\r?$| in)/ or
           ($Cur->{Dll} ne "" and
            $Line =~ /(\Q$Cur->{Dll}\E):([_a-z0-9]*)(?::([0-9a-f]+))? done \((-?\d+)\)(?:\r?$| in)/))
    {
      my ($Dll, $Unit, $Pid, $Rc) = ($1, $2, $3, $4);

      if ($Parser->{IsWineTest} and ($Dll ne $Cur->{Dll} or $Unit ne $Cur->{Unit}))
      {
        # First close the current test unit taking into account
        # it may have been polluted by the new one.
        $Cur->{IsBroken} = 1;
        _CloseTestUnit($Parser, $Cur, 0);

        # Then switch to the new one, warning it's missing a start line,
        # and that its results may be inconsistent.
        ($Cur->{Dll}, $Cur->{Unit}) = ($Dll, $Unit);
        _AddError($Parser, "had no start line (or it is garbled)", $Cur);
        $Cur->{IsBroken} = 1;
      }

      if ($Rc == 258)
      {
        # The done line will already be shown as a timeout (see JobDetails)
        # so record the failure but don't add an error message.
        $Parser->{Failures}++;
        $Cur->{IsBroken} = 1;
        $Parser->{TimedOut} = $Parser->{IsSuite};
      }
      elsif ((!$Pid and !%{$Cur->{Pids}}) or
             ($Pid and !$Cur->{Pids}->{$Pid} and !$Cur->{Pids}->{0}))
      {
        # The main summary line is missing
        if ($Rc & 0xc0000000)
        {
          _AddError($Parser, sprintf("%s:%s crashed (%08x)", $Dll, $Unit, $Rc & 0xffffffff));
          $Cur->{IsBroken} = 1;
        }
        elsif ($Parser->{IsWineTest} and !$Cur->{IsBroken})
        {
           _AddError($Parser, "$Dll:$Unit has no test summary line (early exit of the main process?)");
        }
      }
      elsif ($Rc & 0xc0000000)
      {
        # We know the crash happened in the main process which means we got
        # an "unhandled exception" message. So there is no need to add an
        # extra message or to increment the failure count. Still note that
        # there may be inconsistencies (e.g. unreported todos or skips).
        $Cur->{IsBroken} = 1;
      }
      $Cur->{Rc} = $Rc;
    }
  }
  $Cur->{IsBroken} = 1 if ($Parser->{TaskTimedOut});
  _CloseTestUnit($Parser, $Cur, 1);
  close($LogFile);

  return ($Parser->{Failures}, $Parser->{Errors}, $Parser->{TimedOut});
}


#
# Log querying and formatting
#

=pod
=over 12

=item C<GetLogLineCategory()>

Identifies the category of the given log line: an error message, a todo, just
an informational message or none of these. The category can then be used to
decide whether to hide the line or, on the contrary, highlight it.

=back
=cut

sub GetLogLineCategory($)
{
  my ($Line) = @_;

  if ($Line =~ /: Test marked todo: /)
  {
    return "todo";
  }
  if ($Line =~ /: Tests skipped: / or
      $Line =~ /^[_.a-z0-9-]+:[_a-z0-9]* skipped /)
  {
    return "skip";
  }
  if ($Line =~ /: Test (?:failed|succeeded inside todo block): / or
      $Line =~ /Fatal: test .* does not exist/ or
      $Line =~ / done \(258\)/ or
      $Line =~ /: unhandled exception [0-9a-fA-F]{8} at / or
      $Line =~ /^Unhandled exception: / or
      # Git errors
      $Line =~ /^CONFLICT / or
      $Line =~ /^error: patch failed:/ or
      $Line =~ /^error: corrupt patch / or
      # Build errors
      $Line =~ /: error: / or
      $Line =~ /^make: [*]{3} No rule to make target / or
      $Line =~ /^Makefile:[0-9]+: recipe for target .* failed$/ or
      $Line =~ /^(?:Build|Reconfig|Task): (?!ok)/ or
      # Typical perl errors
      $Line =~ /^Use of uninitialized value/)
  {
    return "error";
  }
  if ($Line =~ /^BotError:/)
  {
    return "boterror";
  }
  if ($Line =~ /^\+ \S/ or
      $Line =~ /^[_.a-z0-9-]+:[_a-z0-9]* start / or
      # Build messages
      $Line =~ /^(?:Build|Reconfig|Task): ok/)
  {
    return "info";
  }

  return "none";
}

=pod
=over 12

=item C<GetLogFileNames()>

Scans the directory for test reports and task logs and returns their filenames.
The filenames are returned in the order in which the logs are meant to be
presented.

=back
=cut

sub GetLogFileNames($;$)
{
  my ($Dir, $IncludeOld) = @_;

  my @Candidates = ("exe32.report", "exe64.report",
                    "win32.report", "wow32.report", "wow64.report",
                    "log", "err");
  push @Candidates, "log.old", "err.old" if ($IncludeOld);

  my @Logs;
  foreach my $FileName (@Candidates)
  {
    push @Logs, $FileName if (-f "$Dir/$FileName" and !-z "$Dir/$FileName");
  }
  return \@Logs;
}

my %_LogFileLabels = (
  "exe32.report" => "32 bit Windows report",
  "exe64.report" => "64 bit Windows report",
  "win32.report" => "32 bit Wine report",
  "wow32.report" => "32 bit WoW Wine report",
  "wow64.report" => "64 bit Wow Wine report",
  "log"          => "task log",
  "err"          => "task errors",
  "log.old"      => "old logs",
  "err.old"      => "old task errors",
);

=pod
=over 12

=item C<GetLogLabel()>

Returns a user-friendly description of the content of the specified log file.

=back
=cut

sub GetLogLabel($)
{
  my ($LogFileName) = @_;
  return $_LogFileLabels{$LogFileName};
}

1;
