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

package WineTestBot::PatchUtils;

=head1 NAME

WineTestBot::PatchUtils - Parse and analyze patches.

=head1 DESCRIPTION

Provides functions to parse patches and figure out which impact they have on
the Wine builds.

=cut

use Exporter 'import';
our @EXPORT = qw(GetPatchImpact);

use WineTestBot::Config;


=pod
=over 12

=item C<GetTestList()>

Returns a hashtable containing the list of the source files for a given module.
This structure is built from the latest/testlist.txt file.

=back
=cut

sub GetTestList()
{
  my $TestList = {};
  if (open(my $File, "<", "$DataDir/latest/testlist.txt"))
  {
    while (my $TestFileName = <$File>)
    {
      chomp $TestFileName;
      if ($TestFileName =~ m~^\w+/([^/]+)/tests/([^/]+)$~)
      {
        my ($Module, $File) = ($1, $2);
        $TestList->{$Module}->{$File} = 1;
      }
    }
    close($File);
  }
  return $TestList;
}

sub _AddTest($$$)
{
  my ($Impacts, $Path, $Change) = @_;

  return if ($Path !~ m~^(dlls|programs)/([^/]+)/tests/([^/\s]+)$~);
  my ($Root, $Module, $File) = ($1, $2, $3);

  my $Tests = $Impacts->{Tests};
  if (!$Tests->{$Module})
  {
    my $ExeBase = ($Root eq "programs") ? "${Module}.exe_test" :
                                          "${Module}_test";
    $Tests->{$Module} = {
      "Type"    => "patch$Root",
      "Module"  => $Module,
      "Path"    => "$Root/$Module/tests",
      "ExeBase" => $ExeBase,
    };
  }

  # Assume makefile modifications may break the build but not the tests
  if ($File eq "Makefile.in")
  {
    if ($Change eq "new" or $Change eq "rm")
    {
      # This adds / removes a directory
      $Impacts->{Makefiles} = 1;
    }
    return;
  }
  return if ($Impacts->{NoUnits});

  if (!$Tests->{$Module}->{Files})
  {
    my $TestList = ( $Impacts->{TestList} ||= GetTestList() );
    foreach my $File (keys %{$TestList->{$Module}})
    {
      $Tests->{$Module}->{Files}->{$File} = 0; # not modified
    }
  }
  $Tests->{$Module}->{Files}->{$File} = $Change;
}

sub dumpstr($)
{
  my ($Str) = @_;
  return defined $Str ? "[$Str]" : "<undef>";
}

=pod
=over 12

=item C<GetPatchImpact()>

Analyzes a patch and returns a hashtable describing the impact it has on the
Wine build: whether it requires updating the makefiles, re-running autoconf or
configure, whether it impacts the tests, etc.

=back
=cut

sub GetPatchImpact($;$)
{
  my ($PatchFileName, $NoUnits) = @_;

  my $fh;
  return undef if (!open($fh, "<", $PatchFileName));

  my $Impacts = {
    NoUnits => $NoUnits,
    Tests => {},
  };
  my ($Path, $Change);
  while (my $Line = <$fh>)
  {
    if ($Line =~ m=^--- \w+/(?:aclocal\.m4|configure\.ac)$=)
    {
      $Impacts->{Autoconf} = 1;
    }
    elsif ($Line =~ m=^--- \w+/configure$=)
    {
      $Impacts->{HasConfigure} = 1;
    }
    elsif ($Line =~ m=^--- \w+/tools/make_makefiles$=)
    {
      $Impacts->{Makefiles} = 1;
    }
    elsif ($Line =~ m=^--- /dev/null$=)
    {
      $Change = "new";
    }
    elsif ($Line =~ m~^--- \w+/([^/]+/[^/]+/tests/[^/\s]+)$~)
    {
      $Path = $1;
    }
    elsif ($Line =~ m~^\+\+\+ /dev/null$~)
    {
      _AddTest($Impacts, $Path, "rm") if (defined $Path);
      $Path = undef;
      $Change = "";
    }
    elsif ($Line =~ m~^\+\+\+ \w+/(\w+/[^/]+/tests/[^/\s]+)$~)
    {
      _AddTest($Impacts, $1, $Change || "modify");
      $Path = undef;
      $Change = "";
    }
    else
    {
      $Path = undef;
      $Change = "";
    }
  }
  close($fh);

  $Impacts->{ModuleCount} = 0;
  $Impacts->{UnitCount} = 0;
  foreach my $Module (keys %{$Impacts->{Tests}})
  {
    my $TestInfo = $Impacts->{Tests}->{$Module};

    # For each module, identify modifications to non-C files and helper dlls
    my $AllUnits;
    foreach my $File (keys %{$TestInfo->{Files}})
    {
      # Skip unmodified files
      next if (!$TestInfo->{Files}->{$File});

      my $Base = $File;
      if ($Base !~ s/(?:\.c|\.spec)$//)
      {
        # Any change to a non-C non-Spec file can potentially impact all tests
        $AllUnits = 1;
        last;
      }
      if (exists $TestInfo->{Files}->{"$Base.spec"} and
             ($TestInfo->{Files}->{"$Base.c"} or
              $TestInfo->{Files}->{"$Base.spec"}))
      {
        # Any change to a helper dll can potentially impact all tests
        $AllUnits = 1;
        last;
      }
    }

    $TestInfo->{Units} = {};
    foreach my $File (keys %{$TestInfo->{Files}})
    {
      # Skip unmodified files
      next if (!$AllUnits and !$TestInfo->{Files}->{$File});

      my $Base = $File;
      # Non-C files are not test units
      next if ($Base !~ s/(?:\.c|\.spec)$//);
      # Helper dlls are not test units
      next if (exists $TestInfo->{Files}->{"$Base.spec"});

      if (($AllUnits or $TestInfo->{Files}->{$File}) and
             $TestInfo->{Files}->{$File} ne "rm")
      {
        # Only new/modified test units are impacted
        $TestInfo->{Units}->{$Base} = 1;
      }
    }

    $TestInfo->{UnitCount} = scalar(%{$TestInfo->{Units}});
    if ($TestInfo->{UnitCount})
    {
      $Impacts->{ModuleCount}++;
      $Impacts->{UnitCount} += $TestInfo->{UnitCount};
    }
  }

  return $Impacts;
}
