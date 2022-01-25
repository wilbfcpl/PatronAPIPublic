# Author:  <wblake@CB95043>
# Created: Dec 7, 2021
# Version: 0.01
#
# Usage: perl [-d] [-r ] [-x]fcps_update.pl filename.csv
# -d Debug/verbose -r read only , no update, -x delete for cleanup of test data
# 
# filename.csv is a file with FCPS Student information for their FCPL Student Success Card Account
# patronid, firstName, middleName, lastName,grade, schoolAddress ,city , state , zip, enrollmentStatus
#
#If the student's account already exists, update it. Otherwise create it.
#
#Read only mode, no updates- check if the student exists. Delete mode - for removing test data.
#Debug mode- a lot more SOAP messages.
#
# Assumes first line of in file has column label headings
#
# Uses local copy of CarlX WSDL file PatronAPI.wsdl for interface to PatronAPI requests GetPatronInformation, UpdatePatron,CreatePatron,DeletePatron
#
# A tool like SOAPUI can provide a sandbox for the WSDL file and PatronAPI requests.
#
# Note that PatronAPI.wsdl may violate rules by responding to CreatePatron and UpdatePatron.
# Note that API call and response return appear to take one second in real time.
#

use strict;
use diagnostics;

# See the CPAN and web pages for XML::Compile::WSDL http://perl.overmeer.net/xml-compile/
use XML::Compile::WSDL11;      # use WSDL version 1.1
use XML::Compile::SOAP11;      # use SOAP version 1.1
use XML::Compile::Transport::SOAPHTTP;
use Time::HiRes qw( gettimeofday tv_interval);
use Data::Dumper;
use Getopt::Std;

# Reduce number of magic values where possible
use constant PATRONTYPE_STUDENT => "STUDNT";
use constant LAST_EDITED_API => 'API';
use constant SEARCHTYPE_PATRONID => 'Patron ID';
use constant MARYLAND => 'MD';
use constant ADDRESS_TYPE_PRIMARY =>'Primary';

#Command line input variable handling
our ($opt_d,$opt_r,$opt_x);
getopts('drx:');

if (defined $opt_d) {
   use Log::Report mode=>'DEBUG';
}


# Results and trace from XML::Compile::WSDL et al.
my $result ;
my $trace;

# Timestamp for the Patron field PATRON_V2. REGDATE 
my $edittime;
my $todaydate;

# Use today if date option not provided
my ($day,$month,$year) = (localtime) [3,4,5];
$year+= 1900;
$month += 1;

$todaydate = "$year-$month-$day";

#Instrumentation for Print Messages
my $local_filename=$0;
 $local_filename =~ s/.+\\([A-z]+.pl)/$1/;
             
            
my $wsdlfile = 'PatronAPInew.wsdl';

my $wsdl = XML::Compile::WSDL11->new($wsdlfile);

unless (defined $wsdl)
{
    die "[$local_filename" . ":" . __LINE__ . "]Failed XML::Compile call\n" ;
}
           
 #my $call1 = $wsdl->compileClient('GetPatronSummaryOverview');
 my $call1 = $wsdl->compileClient('GetPatronInformation');
 my $call2 = $wsdl->compileClient('UpdatePatron');
 my $call3 = $wsdl->compileClient('CreatePatron');
 my $call4 = $wsdl->compileClient('DeletePatron');
 
unless ((defined $call1) && (defined $call2) && (defined $call3) && ( defined $call4) )
  { die "[$local_filename" . ":" . __LINE__ . "] SOAP/WSDL Error $wsdl $call1, $call2 $call3 $call4 \n" ;}
  
    my $newStudents = 0;
    my $updatedStudents = 0;
    my $foundStudents = 0;
    my $notFoundStudents = 0;
    my $deletedStudents = 0;
    
    my ($patronid, $first, $middle, $last,$grade, $address ,$city , $state , $zip, $status);
    
    # Read the input file and ignore the first line having column headings
     $_ = <>;
     chomp;
    ($patronid, $first, $middle, $last,$grade, $address ,$city , $state , $zip, $status,$edittime) = split(/,/);
    
    # Time::HiRes and local Vars to measure time (in seconds) required by API request/response
    my $t0 = 0;
    my $num_calls = 0;
    my $elapsed = 0;
    my $total_time = 0;
    my $avg_time = 0;
  
    # PatronPI Request Vars
    my %PatronRequest ;
    my %PatronUpdateValues;
    my %PatronUpdateRequest;
    my $MyResponseStatusCode;
    
    # PatronAPI Response vars for GetPatronInformation. 
    my $responsePatronID ;
    my $responseFullName ;
    my $responseDefaultBranch ; 
    my $responsePatronStatusCode ;
    my $responseRegisteredBy ;
    my $responseRegistrationDate ; 
    my $responseExpirationDate ;
    my $responseUDFGradeValue ; 
    my $responseUDFNewsletter  ;
    my $responseUDFPreferredLang ; 
    my $responseAddress ;
    
    # Loop until the end of the input file with the first line an assumed header.
    while (<>) {
    chomp;
     ($patronid, $first, $middle, $last,$grade, $address ,$city , $state , $zip, $status,$edittime) = split(/,/);
  
     if ($edittime eq "") {
        $edittime = $todaydate ;
     }
     #Data::Dumper print and the CPAN XML::Compile documentation reveals the PatronAPI response structure   
    %PatronRequest =
    (
    SearchType => 'Patron ID',
    SearchID => $patronid,
    Modifiers=> { DebugMode=>0,
                 ReportMode=>0,}
                 );
     
     %PatronUpdateValues =
     ( PatronID => $patronid,
      FirstName =>$first,
      MiddleName =>$middle,
      LastName =>$last,
      PatronType=>PATRONTYPE_STUDENT,
      PatronStatusCode =>$status,
      RegistrationDate=>$edittime,
      RegisteredBy=>LAST_EDITED_API,
      UserDefinedFields=>{
       cho_UserDefinedField=>
        {UserDefinedField=>
         {
         Field=>'Grade',
         Value=>$grade
         }
        }
       
      },
      Addresses => { cho_Address=>
                        {Address =>
                         {
                          Type =>ADDRESS_TYPE_PRIMARY,
                          Street=>$address,
                          City=>$city,
                          State=>MARYLAND,
                          PostalCode=>$zip
                         }
                        }
                        });
     
     %PatronUpdateRequest =
       (
        SearchType => SEARCHTYPE_PATRONID,
        SearchID => $patronid,
        Patron => \%PatronUpdateValues,
        Modifiers=> {
        DebugMode=>0,
        ReportMode=>0,}
              );
   
   #Time the API Call
   $num_calls += 1;
   $t0 = [gettimeofday];
   
   # Get Patron Summary first
   if (defined $opt_d) {
    ($result, $trace) = $call1->(%PatronRequest);
   
   if($trace->errors) {
    $trace->printErrors;
     }
  }
   else {
      $result = $call1->(%PatronRequest);
    }
   
   
   #print Dumper ($result);
  
   $MyResponseStatusCode = ($result->{GetPatronInformationResponse}->{ResponseStatuses}->{cho_ResponseStatus}[0]->{ResponseStatus}->{Code});
   
   $elapsed = tv_interval ($t0) ;
   $total_time = $total_time + $elapsed;
   
   #print "[$local_filename" . ":" . __LINE__ . "]GetPatronInformation status:$result=>ResponseStatus=>Code\n" ;
  
   #Data::Dumper print and the CPAN XML::Compile documentation reveals the PatronAPI response structure
   
   if ( (defined $MyResponseStatusCode) && ($MyResponseStatusCode == 0) )
     { 
       $foundStudents += 1;
       if (defined $opt_r) {
             $responsePatronID = ($result->{GetPatronInformationResponse}->{Patron}->{PatronID});
             $responseFullName = ($result->{GetPatronInformationResponse}->{Patron}->{FullName});    
             $responseDefaultBranch = ($result->{GetPatronInformationResponse}->{Patron}->{DefaultBranch});
             $responsePatronStatusCode = ($result->{GetPatronInformationResponse}->{Patron}->{PatronStatusCode});
             $responseRegisteredBy = ($result->{GetPatronInformationResponse}->{Patron}->{RegisteredBy});
             $responseRegistrationDate = ($result->{GetPatronInformationResponse}->{Patron}->{RegistrationDate});
             $responseExpirationDate = ($result->{GetPatronInformationResponse}->{Patron}->{ExpirationDate});
             $responseUDFGradeValue = ($result->{GetPatronInformationResponse}->{Patron}->{UserDefinedFields}->{cho_UserDefinedField}[0]->{UserDefinedField}->{Value});
             $responseUDFNewsletter  = ($result->{GetPatronInformationResponse}->{Patron}->{UserDefinedFields}->{cho_UserDefinedField}[1]->{UserDefinedField}->{Value});
             $responseUDFPreferredLang  = ($result->{GetPatronInformationResponse}->{Patron}->{UserDefinedFields}->{cho_UserDefinedField}[2]->{UserDefinedField}->{Value});
             $responseAddress =       ($result->{GetPatronInformationResponse}->{Patron}->{Addresses}->{cho_Address}[0]->{Address}->{Street});
         
             #print "[$local_filename ]FND: $patronid, $first, $middle, $last,$grade, $address ,$city , $state , $zip, $status,$edittime\n";
             #print "[$local_filename ]INF: $responsePatronID, $responseFullName,$responseUDFGradeValue, $responseAddress,$responsePatronStatusCode,$responseRegistrationDate,$responseRegisteredBy,$responseDefaultBranch,$responseExpirationDate\n";
             #print Dumper ($result);
          
             next ;
       }
       else # read only not defined so perform update
       {
         #WSDL does not show output for UpdatePatron so result is dodgy and trace has errors. CreatePatron, too
         #updatePatron
         $updatedStudents += 1;
         if (defined $opt_d) {
          if (defined $opt_x) {
              #delete the account cleanup /further testing
               my ($result4,$trace4)=$call4->(%PatronRequest);
               $deletedStudents += 1;
               if($trace4->errors)
                 { $trace4->printErrors; }
                  print "[$local_filename" . ":" . __LINE__ . "]deleting Student $deletedStudents. Updated: $updatedStudents $_\n" ;
              }
          
          else {
                my ($result2,$trace2)=$call2->(%PatronUpdateRequest);
                if($trace2->errors)
                  { $trace2->printErrors; }
          }
         }
         else { # (!defined $opt_d)
                #delete the account cleanup /further testing
                if (defined $opt_x) {
               
                    my $result4=$call4->(%PatronRequest);
                    $deletedStudents += 1;
                    print "[$local_filename" . ":" . __LINE__ . "]deleting Student $deletedStudents Updated $updatedStudents $_\n" ;
                }
                else {
                    my $result2=$call2->(%PatronUpdateRequest);
                    #    print $wsdl->explain('UpdatePatron', PERL => 'OUTPUT', recurse => 1);
                    print "[$local_filename" . ":" . __LINE__ . "]Updating Student $updatedStudents $_\n" ;
                    #my $MyResponseStatusCode = ($result2->{GenericResponse}->{ResponseStatuses}->{cho_ResponseStatus}[0]->{ResponseStatus}->{Code});
                    #print Dumper ($result2);
                }
         }  
       }
     }
   else {
      #Create a new Patron record
            $notFoundStudents += 1;
            if (defined $opt_r) {     
            print "[$local_filename ]NEW: $patronid, $first, $middle, $last,$grade, $address ,$city , $state , $zip, $status,$edittime\n";
            next ;
             } 
             #createpatron
             if (defined $opt_d ) {
             my ($result3,$trace3)=$call3->(%PatronUpdateRequest);
             }
           else { my ($result3)=$call3->(%PatronUpdateRequest);}
           $newStudents += 1;
           print "[$local_filename" . ":" . __LINE__ . "]Creating Student $newStudents $_\n" ;
       }
    }


$avg_time = $total_time / $num_calls;

print ("[$local_filename" . ":" . __LINE__ . "]API calls: $num_calls time: $total_time avg $avg_time.\n");

print "[$local_filename]Summary Found Students: $foundStudents Not Found Students: $notFoundStudents Updated: $updatedStudents Created: $newStudents\n";
