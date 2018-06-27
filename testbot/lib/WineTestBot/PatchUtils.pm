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
our @EXPORT = qw(GetPatchImpact UpdateWineData);

use WineTestBot::Config;


# These paths are too generic to be proof that this is a Wine patch.
my $AmbiguousPathsRe = join('|',
  'Makefile\.in$',
  # aclocal.m4 gets special treatment
  # configure gets special treatment
  # configure.ac gets special treatment
  'include/Makefile\.in$',
  'include/config\.h\.in$',
  'po/',
  'tools/Makefile.in',
  'tools/config.guess',
  'tools/config.sub',
  'tools/install-sh',
  'tools/makedep.c',
);

# Patches to these paths don't impact the Wine build. So ignore them.
my $IgnoredPathsRe = join('|',
  '\.mailmap$',
  'ANNOUNCE$',
  'AUTHORS$',
  'COPYING\.LIB$',
  'LICENSE\$',
  'LICENSE\.OLD$',
  'MAINTAINERS$',
  'README$',
  'VERSION$',
  'documentation/',
  'tools/c2man\.pl$',
  'tools/winapi/',
  'tools/winemaker/',
);


=pod
=over 12

=item C<UpdateWineData()>

Updates information about the Wine source, such as the list of Wine files,
for use by the TestBot server.

=back
=cut

sub UpdateWineData($)
{
  my ($WineDir) = @_;

  mkdir "$DataDir/latest" if (!-d "$DataDir/latest");

  my $ErrMessage = `cd '$WineDir' && git ls-tree -r --name-only HEAD 2>&1 >'$DataDir/latest/winefiles.txt'`;
  return $ErrMessage if ($? != 0);
}

my $_TimeStamp;
my $_WineFiles;
my $_TestList;

=pod
=over 12

=item C<_LoadWineFiles()>

Reads latest/winefiles.txt to build a per-module hashtable of the test unit
files and a hashtable of all the Wine files.

=back
=cut

sub _LoadWineFiles()
{
  my $FileName = "$DataDir/latest/winefiles.txt";
  my $MTime = (stat($FileName))[9] || 0;

  if ($_TestList and $_TimeStamp == $MTime)
  {
    # The file has not changed since we loaded it
    return;
  }

  $_TimeStamp = $MTime;
  $_TestList = {};
  $_WineFiles = {};
  if (open(my $fh, "<", $FileName))
  {
    while (my $Line = <$fh>)
    {
      chomp $Line;
      $_WineFiles->{$Line} = 1;

      if ($Line =~ m~^\w+/([^/]+)/tests/([^/]+)$~)
      {
        my ($Module, $File) = ($1, $2);
        next if ($File eq "testlist.c");
        next if ($File !~ /\.(?:c|spec)$/);
        $_TestList->{$Module}->{$File} = 1;
      }
    }
    close($fh);
  }
}

sub _HandleFile($$$)
{
  my ($Impacts, $FilePath, $Change) = @_;

  if ($Change eq "new")
  {
    delete $Impacts->{DeletedFiles}->{$FilePath};
    $Impacts->{NewFiles}->{$FilePath} = 1;
  }
  elsif ($Change eq "rm")
  {
    delete $Impacts->{NewFiles}->{$FilePath};
    $Impacts->{DeletedFiles}->{$FilePath} = 1;
  }

  if ($FilePath =~ m~^(dlls|programs)/([^/]+)/tests/([^/\s]+)$~)
  {
    my ($Root, $Module, $File) = ($1, $2, $3);
    $Impacts->{IsWinePatch} = 1;
    $Impacts->{TestBuild} = 1;

    my $Tests = $Impacts->{Tests};
    if (!$Tests->{$Module})
    {
      my $ExeBase = ($Root eq "programs") ? "${Module}.exe_test" :
                                            "${Module}_test";
      $Tests->{$Module} = {
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
        $Impacts->{MakeMakefiles} = 1;
      }
      return;
    }
    return if ($Impacts->{NoUnits});

    if (!$Tests->{$Module}->{Files})
    {
      foreach my $File (keys %{$_TestList->{$Module}})
      {
        $Tests->{$Module}->{Files}->{$File} = 0; # not modified
      }
    }
    $Tests->{$Module}->{Files}->{$File} = $Change;
  }
  elsif ($FilePath =~ m~^(dlls|programs)/([^/]+)/([^/\s]+)$~)
  {
    my ($Root, $Dir, $File) = ($1, $2, $3);
    my $Module = ($Root eq "programs") ? "$Dir.exe" : $Dir;
    $Impacts->{IsWinePatch} = 1;
    $Impacts->{ModuleBuild} = 1;

    if ($File eq "Makefile.in" and $Change ne "modify")
    {
      # This adds / removes a directory
      $Impacts->{MakeMakefiles} = 1;
    }
  }
  else
  {
    my $WineFiles = $Impacts->{WineFiles} || $_WineFiles;
    if ($WineFiles->{$FilePath})
    {
      if ($FilePath !~ /^(?:$AmbiguousPathsRe)/)
      {
        $Impacts->{IsWinePatch} = 1;
      }
      # Else this file exists in Wine but has a very common name so it may just
      # as well belong to another repository. Still update WineBuild in case
      # this patch really is for Wine.

      if ($FilePath !~ /^(?:$IgnoredPathsRe)/)
      {
        $Impacts->{WineBuild} = 1;
      }
      # Else patches to this file don't impact the Wine build.
    }
    elsif ($FilePath =~ m~/Makefile.in$~ and $Change eq "new")
    {
      # This may or may not be a Wine patch but the new Makefile.in will be
      # added to the build by make_makefiles.
      $Impacts->{WineBuild} = $Impacts->{MakeMakefiles} = 1;
    }
  }
}

=pod
=over 12

=item C<GetPatchImpact()>

Analyzes a patch and returns a hashtable describing the impact it has on the
Wine build: whether it requires updating the makefiles, re-running autoconf or
configure, whether it impacts the tests, etc.

=back
=cut

sub GetPatchImpact($;$$)
{
  my ($PatchFileName, $NoUnits, $PastImpacts) = @_;

  my $fh;
  return undef if (!open($fh, "<", $PatchFileName));

  my $Impacts = {
    NoUnits => $NoUnits,
    Tests => {},
  };
  _LoadWineFiles();

  if ($PastImpacts)
  {
    if ($PastImpacts->{WineBuild} or $PastImpacts->{TestBuild})
    {
      # Update the list of Wine files so we correctly recognize patchset parts
      # that modify new Wine files.
      my $WineFiles = $PastImpacts->{WineFiles} || $_WineFiles;
      map { $Impacts->{WineFiles}->{$_} = 1 } keys %{$WineFiles};
      map { $Impacts->{WineFiles}->{$_} = 1 } keys %{$PastImpacts->{NewFiles}};
      map { delete $Impacts->{WineFiles}->{$_} } keys %{$PastImpacts->{DeletedFiles}};
    }
    else
    {
      $Impacts->{NewFiles} = $PastImpacts->{NewFiles};
      $Impacts->{DeletedFiles} = $PastImpacts->{DeletedFiles};
    }

    foreach my $PastInfo (values %{$PastImpacts->{Tests}})
    {
      if ($PastInfo->{Files})
      {
        foreach my $File (keys %{$PastInfo->{Files}})
        {
          _HandleFile($Impacts, "$PastInfo->{Path}/$File",
                      $PastInfo->{Files}->{$File} eq "rm" ? "rm" : 0);
        }
      }
    }
  }

  my ($Path, $Change);
  while (my $Line = <$fh>)
  {
    if ($Line =~ m=^--- \w+/(?:aclocal\.m4|configure\.ac)$=)
    {
      $Impacts->{WineBuild} = $Impacts->{Autoconf} = 1;
    }
    elsif ($Line =~ m=^--- \w+/configure$=)
    {
      $Impacts->{WineBuild} = $Impacts->{HasConfigure} = 1;
    }
    elsif ($Line =~ m=^--- \w+/tools/make_makefiles$=)
    {
      $Impacts->{WineBuild} = $Impacts->{MakeMakefiles} = 1;
      $Impacts->{IsWinePatch} = 1;
    }
    elsif ($Line =~ m=^--- /dev/null$=)
    {
      $Change = "new";
    }
    elsif ($Line =~ m~^--- \w+/([^\s]+)$~)
    {
      $Path = $1;
    }
    elsif ($Line =~ m~^\+\+\+ /dev/null$~)
    {
      _HandleFile($Impacts, $Path, "rm") if (defined $Path);
      $Path = undef;
      $Change = "";
    }
    elsif ($Line =~ m~^\+\+\+ \w+/([^\s]+)$~)
    {
      _HandleFile($Impacts, $1, $Change || "modify");
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
  foreach my $TestInfo (values %{$Impacts->{Tests}})
  {
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

    $TestInfo->{UnitCount} = scalar(keys %{$TestInfo->{Units}});
    if ($TestInfo->{UnitCount})
    {
      $Impacts->{ModuleCount}++;
      $Impacts->{UnitCount} += $TestInfo->{UnitCount};
    }
  }

  return $Impacts;
}

1;
