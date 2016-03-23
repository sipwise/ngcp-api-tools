package NGCP::API::Client;
use strict;
use warnings;
use English qw(-no_match_vars);
use Config::Tiny;
use JSON qw(to_json);
use IO::Socket::SSL;
use LWP::UserAgent;
use Readonly;

Readonly my $cfg => Config::Tiny->read("/etc/default/ngcp-api")
                        or die "Cannot read /etc/default/ngcp-api: $ERRNO";

my %opts = ();

sub new {
    my $class  = shift;
    my $self   = {};

    $opts{host}      = $cfg->{_}->{NGCP_API_IP};
    $opts{port}      = $cfg->{_}->{NGCP_API_PORT};
    $opts{sslverify} = $cfg->{_}->{NGCP_API_SSLVERIFY} || 'yes';
    $opts{auth_user} = $cfg->{_}->{AUTH_SYSTEM_LOGIN};
    $opts{auth_pass} = $cfg->{_}->{AUTH_SYSTEM_PASSWORD};
    $opts{verbose}   = 0;

    return bless $self, $class;
}

sub request {
    my ($self, $method, $uri, $data) = @_;

    my $ua = LWP::UserAgent->new();
    if ($opts{sslverify} eq 'no') {
        $ua->ssl_opts(
            verify_hostname => 0,
            SSL_verify_mode => IO::Socket::SSL::SSL_VERIFY_NONE,
        );
    }

    my $urlbase = sprintf "%s:%s", @{opts}{qw(host port)};
    my $url     = sprintf "https://%s%s", $urlbase, $uri =~ m#^/# ? $uri
                                                                  : "/".$uri;
    $ua->credentials($urlbase, 'api_admin_system',
                     @{opts}{qw(auth_user auth_pass)});

    if($opts{verbose}) {
        $ua->show_progress(1);
        $ua->add_handler("request_send",  sub { shift->dump; return });
        $ua->add_handler("response_done", sub { shift->dump; return });
    }

    my $req = HTTP::Request->new($method, $url);

    if ($method eq "PATCH") {
        $req->header('Content-Type' => 'application/json-patch+json');
    } else {
        $req->header('Content-Type' => 'application/json');
    }
    $req->header('Prefer' => 'return=representation');
    $req->header('NGCP-UserAgent' => 'NGCP::API::Client');

    $data and $req->content(to_json($data));

    my $res = $ua->request($req);

    return NGCP::API::Client::Result->new($res);
}

sub set_verbose {
    my $self = shift;

    $opts{verbose} = shift || 0;

    return;
}

package NGCP::API::Client::Result;
use warnings;
use strict;
use JSON qw(from_json);

my $result;

sub new {
    my ($class, $res_obj) = @_;
    $result = $res_obj;
    return bless {}, $class;
}

sub headers {
    my $self = shift;

    return $result->headers;
}

sub content {
    my $self = shift;

    return $result->content;
}

sub decoded_content {
    my $self = shift;

    return $result->decoded_content;
}

sub as_hash {
    my $self = shift;

    return from_json($result->content, { utf8 => 1 });
}

sub status_line {
    my $self = shift;

    return $result->status_line;
}

sub is_success {
    my $self = shift;

    return $result->is_success;
}

sub result {
    my $self = shift;

    return $result;
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

Return: NGCP::API::Client::Result object

=head2 set_verbose(0|1)

Enable/disable tracing of the request/response.

Return: undef

=head2 NGCP::API::Client::Result->headers()

Return: HTTP::Headers object

=head2 NGCP::API::Client::Result->content()

Return: result as json serialized data

=head2 NGCP::API::Client::Result->decoded_content()

Return: result as json serialized decoded data

=head2 NGCP::API::Client::Result->as_hash()

Return: result as a hash reference

=head2 NGCP::API::Client::Result->is_success()

Return: true if the request is successful

=head2 NGCP::API::Client::Result->status_line()

Return: HTTP status line of the respone

=head2 NGCP::API::Client::Result->result()

Return: raw LWP::UserAgent->result object

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
