package NGCP::API::Client;
use strict;
use warnings;
use English qw(-no_match_vars);
use Config::Tiny;
use JSON qw(to_json);
use IO::Socket::SSL;
use LWP::UserAgent;
use HTTP::Request::Common;
use Readonly;
use Encode;
use Data::Dumper;
my $config;

BEGIN {
    my $cfg_file = "/etc/default/ngcp-api";
    $config = Config::Tiny->read($cfg_file)
                        or die "Cannot read $cfg_file: $ERRNO";
};

Readonly::Scalar my $cfg => $config;

my %opts = ();

sub new {
    my $class  = shift;
    my $self   = {};

    $opts{host}         = $cfg->{_}->{NGCP_API_IP};
    $opts{port}         = $cfg->{_}->{NGCP_API_PORT};
    $opts{iface}        = $cfg->{_}->{NGCP_API_IFACE};
    $opts{sslverify}    = $cfg->{_}->{NGCP_API_SSLVERIFY} || 'yes';
    $opts{sslverify_lb} = $cfg->{_}->{NGCP_API_SSLVERIFY_LOOPBACK} || 'no';
    $opts{read_timeout} = $cfg->{_}->{NGCP_API_READ_TIMEOUT} || 180;
    $opts{auth_user}    = $cfg->{_}->{AUTH_SYSTEM_LOGIN};
    $opts{auth_pass}    = $cfg->{_}->{AUTH_SYSTEM_PASSWORD};
    $opts{verbose}      = 0;
    $opts{get_post}     = 0;

    bless $self, $class;
    $self->set_page_rows($cfg->{_}->{NGCP_API_PAGE_ROWS} // 10);

    return $self;
}

sub _create_ua {
    my ($self, $uri) = @_;
    my $ua = LWP::UserAgent->new();
    if ($opts{sslverify} eq 'no' ||
            ($opts{sslverify_lb} eq 'no' && $opts{iface} =~ /^(lo|dummy)/)) {
        $ua->ssl_opts(
            verify_hostname => 0,
            SSL_verify_mode => IO::Socket::SSL::SSL_VERIFY_NONE,
        );
    }

    my $urlbase = sprintf "%s:%s", @{opts}{qw(host port)};

    $ua->credentials($urlbase, 'api_admin_system', #'api_admin_http'
                     @{opts}{qw(auth_user auth_pass)});

    if($opts{verbose}) {
        $ua->show_progress(1);
        $ua->add_handler("request_send",  sub { shift->dump; return });
        $ua->add_handler("response_done", sub { shift->dump; return });
    }

    $ua->timeout($opts{read_timeout});

    return ($ua,$urlbase);
}

sub set_opts{
    my ($self, $opts_in) = @_;
    my @keys = keys %$opts_in;
    @opts{@keys} = @$opts_in{@keys};
}

sub _create_req {
    my ($self, $method, $url, $params) = @_;
    $params //= {};

    my $req;
    my $make_request_multiform = $params->{make_request_multiform} // 0;
    if($params->{request}){
        $req = $params->{request};
    }else{
        my $data = $params->{data};
        if('HASH' eq ref $data && 'HASH' eq ref $data->{json}
            && !$params->{dont_convert_json}){
            $make_request_multiform = $params->{make_request_multiform} // 1;
    #       data format:
    #       my $data =  {
    #           json => ${
    #               var => "val",
    #               var1 => "val1",
    #           },
    #           filename => [ $path_to_file ],
    #       };
            my $json = JSON->new->allow_nonref;
            $data->{json} = Encode::encode_utf8($json->encode($data->{json}));
            $data = [
                %$data,
                $data->{json},
            ];
        }
        if($make_request_multiform){
            $req = POST $url,
                Content_Type => 'form-data',
                Content => $data;
            $req->method($method);
        } else {
            $req = HTTP::Request->new($method, $url, $params->{headers} ? $params->{headers} : () );
            if($data && !$params->{dont_convert_json}){
                my $json = JSON->new->allow_nonref;
                $req->content(Encode::encode_utf8($json->encode($data)));
            }
        }
    }
    $req->uri($url) if !$req->uri;
    my $headers_requested_hash = {};
    if ('ARRAY' eq ref $params->{headers}) {
        $headers_requested_hash = {@{$params->{headers}}};
    } elsif ('HASH' eq ref $params->{headers}) {
        $headers_requested_hash = {%{$params->{headers}}};
    }

    if(!$params->{request} || !$params->{request}->header('Content-Type')){
        if ($method eq "PATCH") {
            $req->content_type("application/json-patch+json; charset='utf8'");
        } elsif(!$headers_requested_hash->{'Content-Type'} && !$make_request_multiform) {
            $req->content_type("application/json; charset='utf8'");
        }
        if(!$headers_requested_hash->{'Prefer'}) {
            $req->header('Prefer' => 'return=representation');
        }
    }

    $req->header('NGCP-UserAgent' => 'NGCP::API::Client'); #remove for 'api_admin_http'
    return $req;
}

sub _get_url {
    my ($self, $urlbase, $uri) = @_;
    return sprintf "https://%s%s", $urlbase, $uri =~ m#^/# ? $uri : "/".$uri;
}

sub request {
    my ($self, $method, $uri, $data, $params) = @_;

    $params //= {};
    $params->{data} = $data;
    my ($ua,$urlbase) = $self->_create_ua($uri);
    my $request_uri = $self->_get_url($urlbase,$uri);
    my $req = $self->_create_req($method, $request_uri, $params);
    my $res = $ua->request($req);

    return NGCP::API::Client::Result->new($res);
}

sub request_ex {
    my $self = shift;
    my ($method, $uri, $data, $params) = @_;

    my $res_obj = $self->request(@_);
    if ( 'POST' eq $method ) {
        if (299 < $res_obj->code) {
            die($res_obj->code.':'.$res_obj->content);
        } else {
            my ($ua,$urlbase) = $self->_create_ua($uri);
            my $request_uri = $self->_get_url($urlbase,$res_obj->get_created_location);
            my $req = $self->_create_req('GET', $request_uri);
            my $res = $ua->request($req);
            $res_obj = NGCP::API::Client::Result->new($res);
        }
    }
    return $res_obj;
}

sub next_page {
    my ($self, $uri) = @_;

    (my $params = $uri) =~ s/^[^?]+\?//;
    $params =~ s/[&?]rows(=\d+)?//;
    $params =~ s/[&?]page(=\d+)?//;

    unless ($self->{_ua}) {
        ($self->{_ua},$self->{_urlbase}) = $self->_create_ua($uri);
        $self->{_collection_url} = sprintf "https://%s%s%spage=1&rows=%d", $self->{_urlbase},
            $uri =~ m#^/# ? $uri : "/".$uri,
            $uri =~ m#\?# ? '&' : '?',
            $self->{_rows};
    }

    return unless $self->{_collection_url};

    my $req = $self->_create_req('GET', $self->{_collection_url});

    my $res = NGCP::API::Client::Result->new($self->{_ua}->request($req));

    undef $self->{_collection_url};

    my $data = $res->as_hash();
    if ($data && ref($data) eq 'HASH') {
        $uri = $data->{_links}->{next}->{href};
        return $res unless $uri && $uri =~ /page/;
        $uri .= '&'.$params if $params && $uri !~ /\Q$params\E/;
        $self->{_collection_url} = $self->_get_url($self->{_urlbase},$uri) if $uri;
    }

    return $res;
}

sub set_page_rows {
    my ($self,$rows) = @_;

    $self->{_rows} = $rows;
    undef $self->{_collection_url};
    undef $self->{_ua};

    return;
}

sub set_verbose {
    my $self = shift;

    $opts{verbose} = shift || 0;

    return;
}


package NGCP::API::Client::Result;
use warnings;
use strict;
use base qw(HTTP::Response);
use JSON qw(from_json);
use Data::Dumper;

sub new {
    my ($class, $res_obj) = @_;
    my $self = $class->SUPER::new($res_obj->code,
                                  $res_obj->message,
                                  $res_obj->headers,
                                  $res_obj->content);
    $self->{_cached} = undef;
    $self->{_api_endpoint} = undef;#like subscribers or subscriberpreferences
    $self->{_api_endpoint_type} = undef;#type means type of result - collection, item, preferences
    return $self;
}

sub api_endpoint{
    my $self = shift;
    if (@_) {
        $self->{_api_endpoint} = $_[0];
    }else{
        $self->{_api_endpoint} //= $self->get_self_name;
    }
    return $self->{_api_endpoint};
}

sub api_endpoint_type{
    my $self = shift;
    if (@_) {
        $self->{_api_endpoint_type} = $_[0];
    }
    return $self->{_api_endpoint_type};
}

sub as_hash {
    my $self = shift;
    return $self->{_cached} if $self->{_cached};
    my $json = JSON->new->allow_nonref;
    $self->{_cached} = $json->utf8(1)->decode($self->content);
    return $self->{_cached};
}

sub result {
    my $self = shift;

    my $location = $self->headers->header('Location') || '';
    return $self->is_success
        ? sprintf "%s %s", $self->status_line, $location
        : sprintf "%s %s", $self->status_line, $self->content;
}

sub get_embedded_item{
    my $self = shift;
    my($number, $api_endpoint) = @_;
    $number //= 0;
    $api_endpoint //= $self->api_endpoint;
    return $self->as_hash->{_embedded}->{$self->get_link_name($api_endpoint)}->[$number];
}

sub get_link_name{
    my $self = shift;
    my($api_endpoint) = @_;
    $api_endpoint //= $self->api_endpoint;
    return 'ngcp:'.$api_endpoint;
}

sub get_self_name{
    my $self = shift;
    my $href = $self->as_hash->{_links}->{self}->{href};
    my($api_endpoint) = ( $href =~ m!/api/([^/]+)/! );
    return $api_endpoint;
}

sub get_total_count{
    my $self = shift;
    return $self->as_hash->{total_count};
}

sub get_field{
    my $self = shift;
    my($field) = @_;
    return $self->as_hash->{$field};
}

sub get_id{
    my $self = shift;
    return $self->as_hash->{id};
}

sub get_created_location{
    my $self = shift;
    return $self->headers->header('Location');
}

1;

__END__

=pod

=head1 NAME

NGCP::API::Client - Client interface for the REST API

=head1 VERSION

See the package changelog

=head1 COMPATIBILITY

The version is compatible with NGCP platforms version >= mr4.3.x

=head1 SYNOPSIS

=head2

    my $client = new NGCP::API::Client;

    # GET (list)

    my $uri = '/api/customers/';
    my $res = $client->request("GET", $uri);

    # POST (create)

    my $uri = '/api/customers/';
    my $data = { contact_id         => 4,
                 status             => "test",
                 billing_profile_id => 4,
                 type               => "sipaccount" };
    my $res = $client->request("POST", $uri, $data);

    # PUT (update)

    my $uri = '/api/customers/2';
    my $data = { contact_id         => 4,
                 status             => "test",
                 billing_profile_id => 4,
                 type               => "sipaccount" };
    my $res = $client->request("POST", $uri, $data);

    # PATCH (update fields)

    my $uri = '/api/customers/2';
    my $data = [ { op   => "remove",
                   path => "/add_vat" },
                 { op    => "replace",
                   path  => "/contact_id",
                   value => 5 } ];
    my $res = $client->request("PATCH", $uri, $data);

    # DELETE (remove)

    my $uri = '/api/customers/2';
    my $res = $client->request("DELETE", $uri);

    # $res - response is an NGCP::API::Client::Result object

=head1 DESCRIPTION

The client is for internal REST API usage primarily by internal scripts and modules

=head2 new()

Return: NGCP::API::Client object

=head2 request($method, $uri)

Send a REST API request provided by a method (GET,POST,PUT,PATCH,DELETE)

Return: NGCP::API::Client::Result object which is an extended clone of HTTP:Respone

=head2 set_verbose(0|1)

Enable/disable tracing of the request/response.

Return: undef

=head2 NGCP::API::Client::Result->as_hash()

Return: result as a hash reference

=head2 NGCP::API::Client::Result->result()

Return: return a result string based on the request success

=head1 BUGS AND LIMITATIONS

L<https://bugtracker.sipwise.com>

=head1 AUTHOR

Kirill Solomko <ksolomko@sipwise.com>

=head1 LICENSE

This software is Copyright (c) 2016 by Sipwise GmbH, Austria.

All rights reserved. You may not copy, distribute
or modify without prior written permission from
Sipwise GmbH, Austria.

=cut

# vim: sw=4 ts=4 et
