use strict;
use warnings;

use Data::Dumper;

use NGCP::API::Client;
use Clone qw/clone/;
use JSON;
use Cwd 'abs_path';
use File::Basename;

print 'Note that the next tests require at least one sip account customer,subscriber,call,fax,voicemail,sms,xmpp to be present'."\n";

my $SERVER = {
    CALLS => '192.168.1.118',
    XMPP  => '192.168.1.118',
    FAX   => '127.0.0.1',#dummy for now, not used in the executor
    SMS   => '127.0.0.1',#dummy for now, not used in the executor
};
my $AMOUNT = {
    SUBSCRIBERS => 1,#so there will be x2 subscribers - N caller and N callee
    CALLS       => 1,
    SMS         => 1,
    FAX         => 1,
    VOICEMAILS  => 1,
    XMPP        => 1,
};
my $SUBSCRIBERS_EXISTING_ID = {
    caller => [315],
    callee => [317],
};
my $SUBSCRIBER_TEMPLATE = {
    username_format            => 'sub1_%04d',
    username_format_caller     => 'sub1_caller_%04d',
    username_format_callee     => 'sub1_callee_%04d',
    display_name_format        => 'sub1 %04d',
    display_name_format_caller => 'sub1 caller %04d',
    display_name_format_callee => 'sub1 callee %04d',
    password_format            => 'sub_pwd_%04d',
    #we repeate it intentionally, to somplify logic
    password_format_caller     => 'sub_pwd_%04d',
    password_format_callee     => 'sub_pwd_%04d',
    subscriber_data => {
        customer_id => 69,
        domain => '192.168.1.118',
        primary_number => {
            ac => '1',
            cc => '1',
            sn => time(),
        },
        status => 'active',
        username => undef,
        password => undef,
        display_name => undef,
    },
};


my $api_client = new NGCP::API::Client;

my ($subscribers);

if( !( scalar @{$SUBSCRIBERS_EXISTING_ID->{caller}} >= $AMOUNT->{SUBSCRIBERS}
    && scalar @{$SUBSCRIBERS_EXISTING_ID->{callee}} >= $AMOUNT->{SUBSCRIBERS}) )
{
    if(!defined $SUBSCRIBER_TEMPLATE->{subscriber_data}->{domain}){
        die("Precondition not met: need a domain",1);
    }
    my $get_customer_res = $api_client->request('GET','/api/customers/'.$SUBSCRIBER_TEMPLATE->{subscriber_data}->{customer_id});
    #my $get_customer_struct = $get_customer_res->result_struct('customers');
    if(!$get_customer_res->get_id){
        die("Precondition not met: Customer not found", 1);
    }
    my $customer = $get_customer_res->as_hash;
    my $get_contact_res = $api_client->request('GET','/api/customercontacts/'.$customer->{contact_id});
    #my $get_contact_struct = $get_contact_res->result_struct('customercontacts');
    if(!$get_contact_res->get_id){
        die("Precondition not met: Customer contact not found", 1);
    }
    my $get_domain_res = $api_client->request('GET','/api/domains/?domain='.$SUBSCRIBER_TEMPLATE->{subscriber_data}->{domain});
    if(!$get_domain_res->get_total_count){
        die("Precondition not met: Domain \"".$SUBSCRIBER_TEMPLATE->{subscriber_data}->{domain}."\" not found", 1);
    }
    my $contact = $get_contact_res->as_hash;
    my $domain = $get_domain_res->get_embedded_item(0);
    #print Dumper $contact;
    #print Dumper $domain;
    if($contact->{reseller_id} != $domain->{reseller_id}){
        die("Precondition not met: Domain should belong to the reseller_id = ".$customer->{reseller_id}, 1);
    }
}

{#prepare subscribers
    my $type_i = 1;
    foreach my $type (qw/caller callee/){
        my $type_suffix = '_'.$type;
        $subscribers->{$type} //= [];
        my $found = 0;
        for(my $i = 1; $i <= $AMOUNT->{SUBSCRIBERS}; $i++){
            my $subscriber;
            if($SUBSCRIBERS_EXISTING_ID->{$type}->[$i-1]){
                print "$i: existing: $type: ".($SUBSCRIBERS_EXISTING_ID->{$type}->[$i-1] // '').";\n";
                $subscriber = $api_client->request('GET','/api/subscribers/'.$SUBSCRIBERS_EXISTING_ID->{$type}->[$i-1])->as_hash;
            }else{
                my $get_subscriber_res = $api_client->request('GET','/api/subscribers/?username='.sprintf( $SUBSCRIBER_TEMPLATE->{'username_format'.$type_suffix}, $i ));
                if($get_subscriber_res->get_total_count()){
                    $subscriber = $get_subscriber_res->get_embedded_item(0);
                } else {
                    my $data = clone $SUBSCRIBER_TEMPLATE->{subscriber_data};
                    $data->{primary_number}->{sn} .= $i.$type_i;
                    foreach my $field(qw/username password display_name/){
                        $data->{$field} = sprintf( $SUBSCRIBER_TEMPLATE->{$field.'_format'.$type_suffix}, $i );
                    }
                    $subscriber = $api_client->request_ex('POST', '/api/subscribers/', $data)->as_hash;
                }
            }
            $api_client->request('PATCH',
                '/api/subscriberpreferences/'.$subscriber->{id},
                [ {
                    op => 'add',
                    path => '/allow_out_foreign_domain',
                    value => JSON::true
                } ]);

            my $get_faxserversettings_res = $api_client->request('GET',
                '/api/faxserversettings/'.$subscriber->{id});
            my $faxserversettings = $get_faxserversettings_res->as_hash;
            $faxserversettings->{active} = 1;
            $faxserversettings->{password} = 'aaa111';
            $api_client->request('PUT','/api/faxserversettings/'.$subscriber->{id}, $faxserversettings);

            push @{$subscribers->{$type}}, $subscriber;
        }
        $type_i++;
    }
}
{#generate
    for (my $i_item=0; $i_item < $AMOUNT->{SUBSCRIBERS}; $i_item++){
        my $caller = $subscribers->{caller}->[$i_item];
        my $callee = $subscribers->{callee}->[$i_item];
        print "$caller->{id} => $callee->{id};\n";
        my $cmd_full;
        my $cmd = 'perl '.dirname(abs_path($0)).'/ngcp-conversation-executor.pl';
        if($AMOUNT->{CALLS}){
            $cmd_full = "$cmd call $AMOUNT->{CALLS} $SERVER->{CALLS} 5060 0 @{$caller}{qw/domain username password/} 0 @{$callee}{qw/domain username password/} ";
            process_cmd($cmd_full);
        }
        if($AMOUNT->{VOICEMAILS}){
            $api_client->request('PATCH','/api/callforwards/'.$callee->{id},[ {
                'op' => 'add',
                'path' => '/cfu',
                'value' => {
                    'destinations' => [
                        { 'destination' => 'voicebox', 'timeout' => 200},
                    ],
                    'times' => undef,
                },
            } ] );

            $cmd_full = "$cmd voicemail $AMOUNT->{VOICEMAILS} $SERVER->{CALLS} 5060 0 @{$caller}{qw/domain username password/} 0 @{$callee}{qw/domain username password/} ";
            process_cmd($cmd_full);
            $api_client->request('PATCH','/api/callforwards/'.$callee->{id},[ {
                'op' => 'remove',
                'path' => '/cfu',
            } ] );
        }
        if($AMOUNT->{XMPP}){
            $cmd_full = "$cmd xmpp $AMOUNT->{XMPP} $SERVER->{XMPP} 5222 0 @{$caller}{qw/domain username password/} 0 @{$callee}{qw/domain username password/} ";
            process_cmd($cmd_full);
        }
        if($AMOUNT->{SMS}){
            $cmd_full = "$cmd sms $AMOUNT->{SMS} $SERVER->{SMS} 1443 0 @{$caller}{qw/domain username password/} 0 @{$callee}{qw/domain username password/} ";
            process_cmd($cmd_full);
        }
        if($AMOUNT->{FAX}){
            $cmd_full = "$cmd fax $AMOUNT->{FAX} $SERVER->{FAX} 1443 0 @{$caller}{qw/domain username password/} 0 @{$callee}{qw/domain username password/} ";
            process_cmd($cmd_full);
        }

    }
}

sub process_cmd{
    my($cmd_full) = @_;
    print $cmd_full."\n";
    my $time = time();
    `$cmd_full`;
    print "time: ".(time() - $time).";\n";
}
# vim: set tabstop=4 expandtab:
