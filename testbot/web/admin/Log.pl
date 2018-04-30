# -*- Mode: Perl; perl-indent-level: 2; indent-tabs-mode: nil -*-
# Let the administrator download an excerpt of the Engine log
#
# Copyright 2017 Francois Gouget
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

package LogPage;

use ObjectModel::CGI::FreeFormPage;
our @ISA = qw(ObjectModel::CGI::FreeFormPage);

use ObjectModel::BasicPropertyDescriptor;
use WineTestBot::Log;


sub _initialize($$$)
{
  my ($self, $Request, $RequiredRole) = @_;

  my @PropertyDescriptors = (
    CreateBasicPropertyDescriptor("Hours", "Hours", !1, !1, "N", 2),
  );
  $self->SUPER::_initialize($Request, $RequiredRole, \@PropertyDescriptors);
}

sub GetPropertyValue($$)
{
  my ($self, $PropertyDescriptor) = @_;

  my $PropertyName = $PropertyDescriptor->GetName();
  return 1 if ($PropertyName eq "Hours"); # Provides a default value

  return $self->SUPER::GetPropertyValue($PropertyDescriptor);
}

sub GetHeaderText($)
{
  #my ($self) = @_;
  return "Specify how many hours of log messages to get.";
}

sub GetActions($)
{
  my ($self) = @_;

  my $Actions = $self->SUPER::GetActions();
  push @$Actions, "Download";

  return $Actions;
}

sub OnDownload($)
{
  my ($self) = @_;
  $self->Redirect("/admin/SendLog.pl?Hours=". $self->GetParam("Hours")); # does not return
  exit;
}

sub OnAction($$)
{
  my ($self, $Action) = @_;

  return $self->OnDownload() if ($Action eq "Download");
  return $self->SUPER::OnAction($Action);
}

sub GenerateBody($)
{
  my ($self) = @_;

  my $Log = OpenLog();
  if (defined $Log)
  {
    my $Size = (stat($Log))[7];
    $Size = int($Size / 1024 / 1024);
    print "<div class='Content'><p>Log size: $Size MB</p></div>\n\n";
    close($Log);
  }
  $self->SUPER::GenerateBody();
}


package main;

my $Request = shift;

my $LogPage = LogPage->new($Request, "admin");
$LogPage->GeneratePage();
