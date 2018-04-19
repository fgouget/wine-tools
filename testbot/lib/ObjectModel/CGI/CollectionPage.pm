# -*- Mode: Perl; perl-indent-level: 2; indent-tabs-mode: nil -*-
# Base class for list pages
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

package ObjectModel::CGI::CollectionPage;

=head1 NAME

ObjectModel::CGI::CollectionPage - Base class for list pages

=cut

use ObjectModel::CGI::Page;
our @ISA = qw(ObjectModel::CGI::Page);

use ObjectModel::CGI::CollectionBlockForPage;


sub _initialize($$$$)
{
  my ($self, $Request, $RequiredRole, $Collection) = @_;

  $self->{Collection} = $Collection;

  $self->SUPER::_initialize($Request, $RequiredRole);
}

sub GeneratePage($)
{
  my ($self) = @_;

  if ($self->GetParam("Action"))
  {
    my $CollectionBlock = $self->CreateCollectionBlock($self->{Collection});
    $self->{ActionPerformed} = $self->OnAction($CollectionBlock,
                                               $self->GetParam("Action"));
  }

  $self->SUPER::GeneratePage();
}

sub GenerateTitle($)
{
  my ($self) = @_;

  my $Title = $self->GetTitle();
  if ($Title)
  {
    print "<h1>", $self->escapeHTML($Title), "</h1>\n";
  }
}

sub GenerateBody($)
{
  my ($self) = @_;

  print "<div class='CollectionPageBody'>\n";
  $self->GenerateTitle();
  print "<div class='Content'>\n";
  my $CollectionBlock = $self->CreateCollectionBlock($self->{Collection});
  $CollectionBlock->GenerateList();
  print "</div>\n";
  print "</div>\n";
}

sub GenerateFormStart($$)
{
  my ($self, $CollectionBlock) = @_;

  $CollectionBlock->GenerateFormStart();
}

sub GenerateFormEnd($$)
{
  my ($self, $CollectionBlock) = @_;

  $CollectionBlock->GenerateFormEnd();
}

sub GenerateHeaderRow($$$$)
{
  my ($self, $CollectionBlock, $PropertyDescriptors, $Actions) = @_;

  $CollectionBlock->GenerateHeaderRow($PropertyDescriptors, $Actions);
}

sub GenerateDataRow($$$$$$$)
{
  my ($self, $CollectionBlock, $Item, $PropertyDescriptors, $DetailsPage, $Class, $Actions) = @_;

  $CollectionBlock->GenerateDataRow($Item, $PropertyDescriptors, $DetailsPage, $Class, $Actions);
}

sub GenerateDataCell($$$$$)
{
  my ($self, $CollectionBlock, $Item, $PropertyDescriptor, $DetailsPage) = @_;

  $CollectionBlock->GenerateDataCell($Item, $PropertyDescriptor, $DetailsPage);
}

sub CreateCollectionBlock($$)
{
  my ($self, $Collection) = @_;

  return ObjectModel::CGI::CollectionBlockForPage->new($Collection, $self);
}

sub GetDetailsPage($$)
{
  my ($self, $CollectionBlock) = @_;

  return $CollectionBlock->GetDetailsPage();
}

sub GetTitle($)
{
  my ($self) = @_;

  return ucfirst($self->{Collection}->GetCollectionName());
}

sub GetItemActions($$)
{
  my ($self, $CollectionBlock) = @_;

  return $CollectionBlock->GetItemActions();
}

sub GetActions($$)
{
  my ($self, $CollectionBlock) = @_;

  return $CollectionBlock->GetActions();
}

sub DisplayProperty($$$)
{
  my ($self, $CollectionBlock, $PropertyDescriptor) = @_;

  return $CollectionBlock->DisplayProperty($PropertyDescriptor);
}

sub OnAction($$$)
{
  my ($self, $CollectionBlock, $Action) = @_;

  $CollectionBlock->OnAction($Action);
}

sub OnItemAction($$$$)
{
  my ($self, $CollectionBlock, $Item, $Action) = @_;

  return $CollectionBlock->OnItemAction($Item, $Action);
}

sub GetDisplayValue($$$$)
{
  my ($self, $CollectionBlock, $Item, $PropertyDescriptor) = @_;

  return $CollectionBlock->GetDisplayValue($Item, $PropertyDescriptor);
}

sub SortKeys($$$)
{
  my ($self, $CollectionBlock, $Keys) = @_;

  return $CollectionBlock->SortKeys($Keys);
}

1;
