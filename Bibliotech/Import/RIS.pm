# Copyright 2005 Nature Publishing Group
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# The Bibliotech::Import class is a base class for import modules

package Bibliotech::Import::RIS;
use strict;
use base 'Bibliotech::Import';
use Bibliotech::Const;

sub name {
  'RIS';
}

sub version {
  1.0;
}

sub api_version {
  1;
}

sub mime_types {
  (RIS_MIME_TYPE);
}

sub extensions {
  ('ris');
}

sub understands {
  $_[1] =~ /^TY  - \w+$/m ? 1 : 0;
}

sub parse {
  my $self = shift;
  my $doc  = "\n".$self->doc."\n";
  my $blocks = Bibliotech::Import::EntryList->new;
  while ($doc =~ /( ^TY\ \ -\ .*?
		    ^ER\ \ -\s*$ )/xgsm) {
    $blocks->push(Bibliotech::Import::RIS::Entry->new($1));
  }
  $self->data($blocks);
  return 1;
}

package Bibliotech::Import::RIS::Entry;
use strict;
use base 'Bibliotech::Import::Entry::FromData';
use Bibliotech::CitationSource::RIS;

sub parse {
  my ($self, $importer) = @_;
  my $block = $self->block or die 'no block';
  my $ris_parser = Bibliotech::CitationSource::RIS->new($block) or die 'no RIS parser';
  my $noun = $importer->noun;
  my $ris_result = $ris_parser->make_result($noun, $noun.' Import');
  my $ris_type = $ris_result->ris_type;
  $ris_result->is_valid_ris_type
      or die "This record will not be added to your library because the type of entry is not recognised (RIS type \"$ris_type\" is not understood).\n";
  $self->data($ris_result);
  $self->parse_ok(1);
  return 1;
}

sub raw_keywords {
  return Set::Array->new(shift->data->keywords)->flatten;
}

sub keywords {
  shift->split_keywords(qr/[,;\n] */,
			'Keyword line starting with "%s" split from original text into several keywords.');
}

1;
__END__
