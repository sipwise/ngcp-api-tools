package NGCP::API::Client;
use strict;
use warnings;
use English qw(-no_match_vars);
use Config::Tiny;
use JSON qw(to_json);
use IO::Socket::SSL;
use LWP::UserAgent;
use Readonly;

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

sub _create_req {
    my ($self, $method, $url) = @_;
    my $req = HTTP::Request->new($method, $url);

    if ($method eq "PATCH") {
        $req->content_type("application/json-patch+json; charset='utf8'");
    } else {
        $req->content_type("application/json; charset='utf8'");
    }
    $req->header('Prefer' => 'return=representation');
    $req->header('NGCP-UserAgent' => 'NGCP::API::Client'); #remove for 'api_admin_http'
    return $req;
}

sub _get_url {
    my ($self, $urlbase, $uri) = @_;
    return sprintf "https://%s%s", $urlbase, $uri =~ m#^/# ? $uri : "/".$uri;
}

sub request {
    my ($self, $method, $uri, $data) = @_;

    my ($ua,$urlbase) = $self->_create_ua($uri);

    my $req = $self->_create_req($method, $self->_get_url($urlbase,$uri));

    if ($data) {
        $req->content(Encode::encode_utf8(to_json($data)));
    }

    my $res = $ua->request($req);

    return NGCP::API::Client::Result->new($res);
}

sub next_page {
    my ($self, $uri) = @_;

    (my $params = $uri) =~ s/^[^?]+\?//;

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
        return $res unless $uri && $uri =~ /rows/;
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

sub new {
    my ($class, $res_obj) = @_;
    my $self = $class->SUPER::new($res_obj->code,
                                  $res_obj->message,
                                  $res_obj->headers,
                                  $res_obj->content);
    $self->{_cached} = undef;
    return $self;
}

sub as_hash {
    my $self = shift;
    return $self->{_cached} if $self->{_cached};
    $self->{_cached} = from_json($self->content, { utf8 => 1 });
    return $self->{_cached};
}

sub result {
    my $self = shift;

    my $location = $self->headers->header('Location') || '';
    return $self->is_success
        ? sprintf "%s %s", $self->status_line, $location
        : sprintf "%s %s", $self->status_line, $self->content;
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
