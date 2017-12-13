#!/usr/bin/perl -Tw
# -*- Mode: Perl; perl-indent-level: 2; indent-tabs-mode: nil -*-
#
# Performs the 'build' task in the build machine. Specifically this applies a
# conformance test patch, rebuilds the impacted test and retrieves the
# resulting 32 and 64 bit binaries.
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
  if ($0 =~ m=^(/.*)/[^/]+/[^/]+/[^/]+$=)
  {
    $::RootDir = $1;
    unshift @INC, "$::RootDir/lib";
  }
  $::BuildEnv = 1;
}

use WineTestBot::Config;

sub InfoMsg(@)
{
  my $OldUMask = umask(002);
  if (open LOGFILE, ">>$LogDir/Build.log")
  {
    print LOGFILE @_;
    close LOGFILE;
  }
  umask($OldUMask);
}

sub LogMsg(@)
{
  my $OldUMask = umask(002);
  if (open LOGFILE, ">>$LogDir/Build.log")
  {
    print LOGFILE "Build: ", @_;
    close LOGFILE;
  }
  umask($OldUMask);
}

sub FatalError(@)
{
  LogMsg @_;

  exit 1;
}

sub ApplyPatch($$$)
{
  my ($PatchFile, $PatchType, $BaseName) = @_;

  my $NeedBuildNative = !1;
  my $NeedMakeMakefiles = !1;
  my $NeedMakefile = 0;
  my $NeedMakeInclude = !1;
  my $NeedBuildDeps = !1;
  my $NeedImplib = !1;
  my $NeedAutoconf = !1;
  my $NeedConfigure = !1;
  if (open (FH, "<$PatchFile"))
  {
    my $Line;
    while (defined($Line = <FH>) &&
           (! $NeedBuildNative || ! $NeedMakeMakefiles || $NeedMakefile == 0 || ! $NeedMakeInclude ||
            ! $NeedBuildDeps || ! $NeedImplib || ! $NeedAutoconf || ! $NeedConfigure))
    {
      if ($Line =~ m=^diff.*(?:tests/Makefile\.in|Make\.vars\.in|Make\.rules\.in|Maketest\.rules\.in)$=)
      {
        $NeedMakefile = 1;
      }
      elsif ($Line =~ m=^diff.*include/.*\.idl=)
      {
        $NeedMakeInclude = 1;
      }
      elsif ($Line =~ m=^diff.*\.spec=)
      {
        $NeedBuildDeps = 1;
      }
      elsif ($PatchType eq "dlls" && $Line =~ m=^diff.*$BaseName/Makefile\.in=)
      {
        $NeedImplib = 1;
      }
      elsif ($Line =~ m=^diff.*configure\.ac=)
      {
        $NeedAutoconf = 1;
      }
      elsif ($Line =~ m=^diff.*configure=)
      {
        $NeedConfigure = 1;
      }
      elsif ($Line =~ m=^new file= || $Line =~ m=^deleted file= || $Line =~ m=^rename= ||
             $Line =~ m=diff.*tools/make_makefiles=)
      {
        $NeedMakeMakefiles = $NeedConfigure = 1;
      }
      elsif ($Line =~ m=^diff.*tools/makedep.c=)
      {
        $NeedBuildNative = $NeedMakeMakefiles = $NeedConfigure = 1;
      }
      elsif ($Line =~ m=^diff.*tools/(?:winebuild|wrc)=)
      {
        $NeedBuildNative = 1;
      }
    }
    close FH;
  }

  InfoMsg "Applying patch\n";
  system("( cd $DataDir/wine && set -x && " .
         "  git apply --verbose $PatchFile && " .
         "  git add -A " .
         ") >> $LogDir/Build.log 2>&1");
  if ($? != 0)
  {
    LogMsg "Patch failed to apply\n";
    return (-1, $NeedMakeInclude, $NeedBuildDeps, $NeedImplib, $NeedConfigure);
  }

  if ($NeedBuildNative)
  {
    InfoMsg "Building tools\n";
    if (!BuildNative())
    {
      return (-1, $NeedMakeInclude, $NeedBuildDeps, $NeedImplib, $NeedConfigure);
    }
  }

  if ($NeedMakeMakefiles)
  {
    InfoMsg "Running make_makefiles\n";
    system("( cd $DataDir/wine && set -x && " .
           " ./tools/make_makefiles " .
           ") >> $LogDir/Build.log 2>&1");
    if ($? != 0)
    {
      LogMsg "make_makefiles failed\n";
      return (-1, $NeedMakeInclude, $NeedBuildDeps, $NeedImplib, $NeedConfigure);
    }
  }

  if ($NeedAutoconf && ! $NeedConfigure)
  {
    InfoMsg "Running autoconf\n";
    system("( cd $DataDir/wine && set -x && " .
           "  autoconf --output configure configure.ac " .
           ") >>$LogDir/Build.log 2>&1");
    if ($? != 0)
    {
       LogMsg "Autoconf failed\n";
       return (-1, $NeedMakeInclude, $NeedBuildDeps, $NeedImplib,
               $NeedConfigure);
    }
    $NeedConfigure = 1;
  }

  if ($NeedImplib)
  {
    if (open (FH, "<$DataDir/wine/$PatchType/$BaseName/Makefile.in"))
    {
      $NeedImplib = !1;
      my $Line;
      while (defined($Line = <FH>) && ! $NeedImplib)
      {
        $NeedImplib = ($Line =~ m/^\s*IMPORTLIB\s*=.*$BaseName/)
      }
      close FH;
    }
  }

  return ($NeedMakefile, $NeedMakeInclude, $NeedBuildDeps, $NeedImplib,
          $NeedConfigure);
}

my $ncpus;
sub CountCPUs()
{
    if (open(my $fh, "<", "/proc/cpuinfo"))
    {
        # Linux
        map { $ncpus++ if (/^processor/); } <$fh>;
        close($fh);
    }
    $ncpus ||= 1;
}

sub BuildNative()
{
  mkdir "$DataDir/build-native" if (! -d "$DataDir/build-native");
  system("( cd $DataDir/build-native && set -x && " .
         "  rm -rf * && " .
         "  time ../wine/configure --enable-win64 --without-x --without-freetype && " .
         "  time make -j$ncpus depend && " .
         "  time make -j$ncpus __tooldeps__ " .
         ") >>$LogDir/Build.log 2>&1");

  if ($? != 0)
  {
    LogMsg "Build native failed\n";
    return !1;
  }

  return 1;
}

sub BuildTestExecutable($$$$$$$$)
{
  my ($BaseName, $PatchType, $Bits, $NeedConfigure, $NeedMakefile,
      $NeedMakeInclude, $NeedBuildDeps, $NeedImplib) = @_;

  if ($NeedConfigure)
  {
    InfoMsg "Reconfigure $Bits-bit crossbuild\n";
    my $Host = ($Bits == 64 ? "x86_64-w64-mingw32" : "i686-w64-mingw32");
    system("( cd $DataDir/build-mingw$Bits && set -x && " .
           "  time ../wine/configure --host=$Host --with-wine-tools=../build-native --without-x --without-freetype " .
           ") >>$LogDir/Build.log 2>&1");
    if ($? != 0)
    {
      LogMsg "Reconfigure of $Bits-bit crossbuild failed\n";
      return !1;
    }
  }

  if ($NeedMakeInclude || $NeedConfigure)
  {
    InfoMsg "Recreating include/Makefile\n";
    system("( cd $DataDir/build-mingw$Bits && set -x && " .
           "  time make -j$ncpus include/Makefile " .
           ") >>$LogDir/Build.log 2>&1");
    if ($? != 0)
    {
      LogMsg "Recreation of include/Makefile failed\n";
      return !1;
    }

    system("( cd $DataDir/build-mingw$Bits && set -x && " .
           "  time make -j$ncpus include " .
           ") >> $LogDir/Build.log 2>&1");
    if ($? != 0)
    {
      LogMsg "Make in include dir failed\n";
      return !1;
    }
  }

  if ($NeedImplib || $NeedConfigure)
  {
    InfoMsg "Rebuilding $BaseName import lib\n";
    system("( cd $DataDir/build-mingw$Bits && set -x && " .
           "  time make -j$ncpus $PatchType/$BaseName/Makefile " .
           ") >>$LogDir/Build.log 2>&1");
    if ($? != 0)
    {
      LogMsg "Unable to regenerate $PatchType/$BaseName/Makefile\n";
    }
    else
    {
      system("( cd $DataDir/build-mingw$Bits && set -x && " .
             "  time make -j$ncpus -C $PatchType/$BaseName lib$BaseName.a " .
             ") >>$LogDir/Build.log 2>&1");
      if ($? != 0)
      {
        InfoMsg "Make of import library failed\n";
      }
    }
  }

  if ($NeedMakefile || $NeedConfigure)
  {
    InfoMsg "Recreating tests/Makefile\n";
    system("( cd $DataDir/build-mingw$Bits && set -x && " .
           "  time make -j$ncpus $PatchType/$BaseName/tests/Makefile " .
           ") >>$LogDir/Build.log 2>&1");
    if ($? != 0)
    {
      LogMsg "Recreation of tests/Makefile failed\n";
      return !1;
    }
  }

  if ($NeedBuildDeps)
  {
    InfoMsg "Making build dependencies\n";
    system("( cd $DataDir/build-mingw$Bits && set -x && " .
           "  time make -j$ncpus __builddeps__ " .
           ") >>$LogDir/Build.log 2>&1");
    if ($? != 0)
    {
      LogMsg "Making build dependencies failed\n";
      return !1;
    }
  }

  my $TestsDir = "$PatchType/$BaseName/tests";
  my $TestExecutable = "$TestsDir/$BaseName";
  if ($PatchType eq "programs")
  {
    $TestExecutable .= ".exe";
  }
  $TestExecutable .= "_test.exe";
  unlink("$DataDir/build-mingw${Bits}/$TestExecutable");

  InfoMsg "Making test executable\n";
  system("( cd $DataDir/build-mingw$Bits && set -x && " .
         "  time make -j$ncpus -C $TestsDir " .
         ") >>$LogDir/Build.log 2>&1");
  if ($? != 0)
  {
    LogMsg "Make failed\n";
    return !1;
  }
  if (! -f "$DataDir/build-mingw${Bits}/$TestExecutable")
  {
    LogMsg "Make didn't produce a $TestExecutable file\n";
    return !1;
  }

  return 1;
}

$ENV{PATH} = "/usr/lib/ccache:/usr/bin:/bin";
delete $ENV{ENV};

# Start with clean logfile
unlink("$LogDir/Build.log");

my ($PatchFile, $PatchType, $BaseName, $BitIndicators) = @ARGV;
if (! $PatchFile || ! $PatchType || ! $BaseName || !$BitIndicators)
{
  FatalError "Usage: Build.pl <patchfile> <patchtype> <basename> <bits>\n";
}

# Untaint parameters
if ($PatchFile =~ m/^([\w_.\-]+)$/)
{
  $PatchFile = "$DataDir/staging/$1";
  if (! -r $PatchFile)
  {
    FatalError "Patch file $PatchFile not readable\n";
  }
}
else
{
  FatalError "Invalid patch file $PatchFile\n";
}

if ($PatchType =~ m/^patch(dlls|programs)$/)
{
  $PatchType = $1;
}
else
{
  FatalError "Invalid patch type $PatchType\n";
}

if ($BaseName =~ m/^([\w_.\-]+)$/)
{
  $BaseName = $1;
}
else
{
  FatalError "Invalid DLL base name $BaseName\n";
}

my $Run32 = !1;
my $Run64 = !1;
if ($BitIndicators =~ m/^([\d,]+)$/)
{
  my @Bits = split /,/, $1;
  foreach my $BitsValue (@Bits)
  {
    if ($BitsValue == 32)
    {
      $Run32 = 1;
    }
    elsif ($BitsValue == 64)
    {
      $Run64 = 1;
    }
    else
    {
      FatalError "Invalid number of bits $BitsValue\n";
    }
  }
  if (! $Run32 && ! $Run64)
  {
    FatalError "Specify at least one of 32 or 64 bits\n";
  }
}
else
{
  FatalError "Invalid number of bits $BitIndicators\n";
}

my ($NeedMakefile, $NeedMakeInclude, $NeedBuildDeps, $NeedImplib,
    $NeedConfigure) = ApplyPatch($PatchFile, $PatchType, $BaseName);
if ($NeedMakefile < 0)
{
  exit(1);
}

CountCPUs();

if ($Run32 && ! BuildTestExecutable($BaseName, $PatchType, 32,
                                    $NeedConfigure, 0 < $NeedMakefile,
                                    $NeedMakeInclude, $NeedBuildDeps,
                                    $NeedImplib))
{
  exit(1);
}
if ($Run64 && ! BuildTestExecutable($BaseName, $PatchType, 64,
                                    $NeedConfigure, 0 < $NeedMakefile,
                                    $NeedMakeInclude, $NeedBuildDeps,
                                    $NeedImplib))
{
  exit(1);
}

LogMsg "ok\n";
exit;
