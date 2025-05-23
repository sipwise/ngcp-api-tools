use strict;
use warnings;

use Module::Build qw();
my $builder = Module::Build->new(
    module_name       => 'NGCP-API-Client',
    license           => 'gpl',
    dist_author       => 'Kirill Solomko <ksolomko@sipwise.com>',
    dist_version_from => 'lib/NGCP/API/Client.pm',
    requires          => {
        'Config::Tiny'      => 0,
        'IO::Socket::SSL'   => 0,
        'JSON::XS'          => 0,
        'LWP::UserAgent'    => 0,
        'Readonly'          => 0,
    },
    recommends        => {
        'NGCP::Panel'       => 0,
    },
);
$builder->create_build_script;
