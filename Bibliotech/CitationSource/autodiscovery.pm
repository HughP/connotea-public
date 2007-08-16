# Copyright 2005 Nature Publishing Group
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# The Bibliotech::CitationSource::autodiscovery class retrieves citation data for BioMed Central journals
#		1. parse the HTML of the URL, to get the citation metadata (embedded RDF in a comment)
#		2. parse RDF with RDF::Core::Model::Parser to get citation data
#

package Bibliotech::CitationSource::autodiscovery;
use strict;

use Bibliotech::CitationSource;
use base 'Bibliotech::CitationSource';

use Bibliotech::CitationSource::Simple;

use HTTP::Request::Common;

use URI;
use URI::QueryParam;

use Data::Dumper;

sub api_version {
  1;
}

sub name {
  'autodiscovery';
}

sub cfgname {
  'autodiscovery';
}

sub version {
  '1.1.2.6';
}

sub understands {
  my ($self, $uri, $getURLContent_sub) = @_;

  return 0 unless $uri->scheme eq 'http';

  $self->clearContent;
	$self->warnstr("");

  my ($ok, $response) = $self->catch_transient_warnstr(sub { $self->getURLContent($getURLContent_sub || $uri) });
  $ok or return -1;

  # check for html
  my $content_type = $response->content_type;
  $content_type eq 'text/html' || $content_type eq 'application/xhtml+xml'
      or return 0;
  
  # check html for RDF data, else return 0
  $self->{rdf_content} = getRDFinaComment($response->content)
      or return 0;

  my $metadata;
  ($ok, $metadata) = $self->catch_transient_warnstr(sub {
    Bibliotech::CitationSource::autodiscovery::Metadata->new($self->{rdf_content}, $uri);
  });
  $ok or return 0;

  return 0 unless $metadata;
  $self->{metadata} = $metadata;

  # since this is a less specific plug-in, return a 2 in the event a more specific plug-in recognizes this site
  # the blog plug-in returns 3, so embedded metadata is prefered to linked metadata
  return 2;
}

sub clearContent {
  # noop
}

sub getURLContent {
  my ($self, $content_sub_or_uri) = @_;

  my $response = do {
    if (ref($content_sub_or_uri) eq 'CODE') {
      ($content_sub_or_uri->())[0];
    }
    else {
      my $ua = $self->ua;
      scalar $ua->request(GET $content_sub_or_uri);
    }
  };

  die $response->status_line."\n" unless $response->is_success;
  return $response;
}

sub getRDFinaComment {
  my $content = shift or return;
  local $/ = undef;
  my ($rdf) = $content =~ m,<!--\s+(<rdf:RDF.+?</rdf:RDF>)\s+-->,gs;
  return $rdf;
}

sub citations {
  my ($self, $uri) = @_; 

  # in understands, see if header type html, and has RDF in a comment
  return undef unless($self->understands($uri));

  my $metadata;
  eval {
    $metadata = $self->{metadata};
    die "RDF obj false\n" unless $metadata;
    die "RDF file contained no data\n" unless $metadata->{'has_data'};
  };    

  if ($@) {
    $self->errstr($@);
    return undef;
  }

  return undef unless defined $metadata;

  return Bibliotech::CitationSource::ResultList->new(Bibliotech::CitationSource::Result::Simple->new($metadata));
}

package Bibliotech::CitationSource::autodiscovery::Metadata;
use base 'Class::Accessor::Fast';
use Data::Dumper;

use RDF::Core::Storage::Memory;
use RDF::Core::Model;
use RDF::Core::Model::Parser;
use RDF::Core::Resource;

__PACKAGE__->mk_accessors(qw/doi volume issue journal title author pubdate url has_data/);

#
# needed for RDF::Core::Resource
#		may need to add more resource locations if future sites using the "RDF in a comment" scheme
#		use models other than DC and PRISM.
#
use constant DC_LOC => 'http://purl.org/dc/elements/1.1/';
use constant PRISM_LOC => 'http://prismstandard.org/namespaces/1.2/basic/';

# 
# parse with RDF::Core::Model::Parser 
#
sub new {
  my ($class, $rdf_content, $url) = @_;
  my $self = {};

  # store model in memory
  my $storage = new RDF::Core::Storage::Memory;

  # model to store RDF statements
  my $model = new RDF::Core::Model(Storage=>$storage);

  # create parser
  my $parser = new RDF::Core::Model::Parser(Model=>$model,
					    BaseURI=>$url,
					    Source=>$rdf_content, 
					    SourceType=>'string'
					    );
  bless $self, ref $class || $class;
  $self->has_data(0);
  $self->parse($model, $parser);
  return $self;
}

sub parse {
  my($self, $model, $parser) = @_;

  # parse
  $parser->parse;

	# to see contents
	## 11/18/06 print Dumper($parser) . "\n";

	# identifier ought to be: doi, isbn or uri/url
  my $id = $self->getElement($model, DC_LOC, "identifier");

	my $doi = $id if ($id =~ m/doi/);
  my $pname = $self->getElement($model, PRISM_LOC, "publicationName");
  my $pdate = $self->getElement($model, DC_LOC, "date");
  my $volume = $self->getElement($model, PRISM_LOC, "volume");
  my $issue = $self->getElement($model, PRISM_LOC, "number");
  my $pageNo = $self->getElement($model, PRISM_LOC, "startingPage");
  my $title = $self->getElement($model, DC_LOC, "title");

  my ($authors) = $self->getAuthors($model, DC_LOC, "creator");

  #check it's worth returning
  unless ($pname && $pdate) {
    die "Insufficient metadata extracted for doi: [$doi]\n";
  }

  # clean doi
  my $new = $doi;
  $new =~ s,info:doi/(.*?)$,$1,g;
  $doi = $new if $new;

  # clean date ex. 2006-09-19T07:18:02-05:00
  ($new) = $pdate =~ m,([\d-]+),g;
  $pdate = $new if $new;

  # load the results
  $self->{'has_data'} = 1;
  $self->{'doi'} = $doi;
  $self->{'journal'}->{'name'} = $pname;
  $self->{'volume'} = $volume;
  $self->{'issue'} = $issue;
  $self->{'title'} = $title;
  $self->{'pubdate'} = $pdate;
  $self->{'page'} = $pageNo;
  $self->{'authors'} = $authors;
}

#
# use this method when only one instance
#
sub getElement {
  my($self, $model, $resource_loc, $element) = @_;

  my $resource = RDF::Core::Resource->new($resource_loc . "$element");
  my $resource_enum=$model->getStmts(undef, $resource, undef);
	
  my $label = "";
  my $stmt = $resource_enum->getFirst;

  if(defined $stmt) {
    $label = $stmt->getObject->getLabel;
  }
  
  return $label;
}

#
# use this method when multiple instances
#
sub getList {
  my($self, $model, $resource_loc, $element) = @_;

  my $resource = RDF::Core::Resource->new($resource_loc . "$element");
  my $resource_enum=$model->getStmts(undef, $resource, undef);

  my @list;
  my $stmt = $resource_enum->getFirst;
  while (defined $stmt) {
    my $label = $stmt->getObject->getLabel;
    
    push (@list, $label);
    $stmt = $resource_enum->getNext;
  }
  
  #print "LIST " . Dumper(\@list);
  return @list;
}

sub getAuthors {
  my($self, $model, $resource_loc, $element) = @_;

  my @auList;
  my (@list) = $self->getList($model, $resource_loc, $element);

  # build names foreach author
  # ex. Reguly, Teresa
  foreach my $author (@list) {
    my($l, $f) = $author =~ /^(.*),\s+(.+)$/;
    
    my $name;
    $name->{'forename'} = $f if $f;
    $name->{'lastname'} = $l if $l;
    push(@auList, $name) if $name;
  }
  
  #print "AULIST " . Dumper(\@auList) . "\n";

  return \@auList if @auList;
  return undef unless @auList;
}


1;
__END__