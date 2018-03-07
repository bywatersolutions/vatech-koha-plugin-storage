package Koha::Plugin::Com::ByWaterSolutions::Storage;

## It's good practive to use Modern::Perl
use Modern::Perl;

## Required for all plugins
use base qw(Koha::Plugins::Base);

## We will also need to include any Koha libraries we want to access
use C4::Context;
use C4::Members;
use C4::Auth;
use Koha::DateUtils;
use Koha::Libraries;
use Koha::Patron::Categories;
use Koha::Account;
use Koha::Items;
use Koha::Account::Lines;
use MARC::Record;
use Cwd qw(abs_path);
use URI::Escape qw(uri_unescape);
use LWP::UserAgent;
use DDP;

## Here we set our plugin version
our $VERSION = "{VERSION}";

## Here is our metadata, some keys are required, some are optional
our $metadata = {
    name            => 'Storage Plugin',
    author          => 'Nick Clemens',
    date_authored   => '2018-03-02',
    date_updated    => "1900-01-01",
    minimum_version => '16.06.00.018',
    maximum_version => undef,
    version         => $VERSION,
    description     => 'This plugin implements some remote storage utilities '
};

## This is the minimum code required for a plugin's 'new' method
## More can be added, but none should be removed
sub new {
    my ( $class, $args ) = @_;

    ## We need to add our metadata here so our base class can access it
    $args->{'metadata'} = $metadata;
    $args->{'metadata'}->{'class'} = $class;

    ## Here, we call the 'new' method for our base class
    ## This runs some additional magic and checking
    ## and returns our actual $self
    my $self = $class->SUPER::new($args);

    return $self;
}

## The existance of a 'report' subroutine means the plugin is capable
## of running a report. This example report can output a list of patrons
## either as HTML or as a CSV file. Technically, you could put all your code
## in the report method, but that would be a really poor way to write code
## for all but the simplest reports
sub report {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};

    if ( $cgi->param('courier') ) { $self->courier(); }
    elsif ( $cgi->param('pull_list') ) { $self->pull_list(); }
    elsif ( $cgi->param('reshelve') ) { $self->reshelve(); }
    elsif ( $cgi->param('inventory') ) { $self->inventory(); }
    elsif ( $cgi->param('discard') ) { $self->discard(); }
    elsif ( $cgi->param('accession') ) { $self->accession(); }
    else {
        $self->report_step1();
    }
}


## you will want to add a 'configure' method to your plugin like so.
## Here I am throwing all the logic into the 'configure' method, but it could
## be split up like the 'report' method is.
sub configure {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};

    unless ( $cgi->param('save') ) {
        my $template = $self->get_template({ file => 'configure.tt' });

        ## Grab the values we already have for our settings, if any exist
        $template->param(
            enable_opac_payments => $self->retrieve_data('enable_opac_payments'),
            foo             => $self->retrieve_data('foo'),
            bar             => $self->retrieve_data('bar'),
        );

        print $cgi->header();
        print $template->output();
    }
    else {
        $self->store_data(
            {
                enable_opac_payments => $cgi->param('enable_opac_payments'),
                foo                => $cgi->param('foo'),
                bar                => $cgi->param('bar'),
                last_configured_by => C4::Context->userenv->{'number'},
            }
        );
        $self->go_home();
    }
}

## This is the 'install' method. Any database tables or other setup that should
## be done when the plugin if first installed should be executed in this method.
## The installation method should always return true if the installation succeeded
## or false if it failed.
sub install() {
    my ( $self, $args ) = @_;

    my $table = $self->get_qualified_table_name('mytable');

    return C4::Context->dbh->do( "
        CREATE TABLE  $table (
            `borrowernumber` INT( 11 ) NOT NULL
        ) ENGINE = INNODB;
    " );
}

## This method will be run just before the plugin files are deleted
## when a plugin is uninstalled. It is good practice to clean up
## after ourselves!
sub uninstall() {
    my ( $self, $args ) = @_;

    my $table = $self->get_qualified_table_name('mytable');

    return C4::Context->dbh->do("DROP TABLE $table");
}

## These are helper functions that are specific to this plugin
## You can manage the control flow of your plugin any
## way you wish, but I find this is a good approach
sub report_step1 {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};

    my $template = $self->get_template({ file => 'report-step1.tt' });

    print $cgi->header();
    print $template->output();
}

sub courier {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};

    my $dbh = C4::Context->dbh;

    my $query = "
        SELECT bt.*, title, author, barcode, itemnumber, biblionumber,enumchron, stocknumber
        FROM branchtransfers bt
        LEFT JOIN items USING (itemnumber)
        LEFT JOIN biblio USING (biblionumber)
        WHERE datearrived IS NULL
        ORDER BY frombranch,tobranch
    ";

    my $sth = $dbh->prepare($query);
    $sth->execute();

    my @results;
    while ( my $row = $sth->fetchrow_hashref() ) {
        push( @results, $row );
    }

    print $cgi->header();
    my $filename = 'courier.tt';
    my $template = $self->get_template({ file => $filename });

    $template->param(
        date_ran     => dt_from_string(),
        results_loop => \@results,
    );

    print $template->output();
}

sub pull_list {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};

    my $dbh = C4::Context->dbh;
    my $branch = $cgi->param('branch') || C4::Context->userenv->{'branch'};

    my $query = "
        SELECT *
        FROM tmp_holdsqueue
        JOIN biblio USING (biblionumber)
        JOIN items USING (itemnumber)
        WHERE pickbranch LIKE '$branch'
        ";

    my $sth = $dbh->prepare($query);
    $sth->execute();

    my @results;
    while ( my $row = $sth->fetchrow_hashref() ) {
        push( @results, $row );
    }

    print $cgi->header();
    my $filename = 'pull_list.tt';
    my $template = $self->get_template({ file => $filename });

    $template->param(
        date_ran     => dt_from_string(),
        results_loop => \@results,
        branch => $branch,
    );

    print $template->output();
}

sub reshelve {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};
    print $cgi->header();
    my $filename = 'reshelve.tt';
    my $template = $self->get_template({ file => $filename });
    $template->param( inventory => 1, stocknumber => $cgi->param('stocknumber') ) if $cgi->param('inventory');

    my $barcode_list = $cgi->param('barcode_list');
    if( $barcode_list ) {
        my @barcodes = split /\s\n/, $barcode_list;
        my @items = Koha::Items->search({ barcode => { -in => \@barcodes } });
        $template->param( items => \@items);
        my %found = map { lc $_->barcode => 1 } @items;
        my @not_found;
        foreach my $barcode ( @barcodes ){
            push (@not_found, $barcode) unless defined $found{lc $barcode};
        }
        $template->param( not_found => \@not_found );

    }

    $template->param( date_ran => dt_from_string() );

    print $template->output();
}

sub inventory {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};
    print $cgi->header();
    my $filename = 'inventory.tt';
    my $template = $self->get_template({ file => $filename });

    my $stocknumber  = $cgi->param('stocknumber');
    my $barcode_list = $cgi->param('barcode_list');
    if( $barcode_list ) {
        my @barcodes = split /\s\n/, $barcode_list;
        my @items = Koha::Items->search({ barcode => { -in => \@barcodes } });
        $template->param( items => \@items);
        my %found = map { lc $_->barcode => 1 } @items;
        my @not_found;
        foreach my $barcode ( @barcodes ){
            push (@not_found, $barcode) unless defined $found{lc $barcode};
        }
        $template->param( not_found => \@not_found );
    }

    $template->param( date_ran => dt_from_string(), stocknumber => $stocknumber );

    print $template->output();
}

sub discard {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};

    my $dbh = C4::Context->dbh;

    my $query = "
        SELECT firstname, surname, address, city, zipcode, city, zipcode, dateexpiry FROM borrowers 
    ";

    my $sth = $dbh->prepare($query);
    $sth->execute();

    my @results;
    while ( my $row = $sth->fetchrow_hashref() ) {
        push( @results, $row );
    }

    print $cgi->header();
    my $filename = 'report-step2-html.tt';
    my $template = $self->get_template({ file => $filename });

    $template->param(
        date_ran     => dt_from_string(),
        results_loop => \@results,
    );

    print $template->output();
}

sub accession {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};

    my $next_step = $cgi->param('next_step');
    print $cgi->header();
    my $filename = 'accession.tt';
    my $template = $self->get_template({ file => $filename });
    $template->param( date_ran => dt_from_string() );
    unless ($next_step) {
        $template->param(step_1 => 1);
        print $template->output();
    } elsif ($next_step == 2) {
        my $barcode_list = $cgi->param('barcode_list');
        my $stocknumber = $cgi->param('stocknumber');
        if ( $barcode_list ){
            my @barcodes = split /\s\n/, $barcode_list;
            my @items = Koha::Items->search({ barcode => { -in => \@barcodes } });
            $template->param( items => \@items);
            my %found = map { lc $_->barcode => 1 } @items;
            my @not_found;
            foreach my $barcode ( @barcodes ){
               push (@not_found, $barcode) unless defined $found{lc $barcode};
            }
            $template->param( not_found => \@not_found );
        }
        $template->param(step_2 => 1);
        $template->param(stocknumber => $stocknumber);
        print $template->output();
    } elsif ($next_step == 3) {
        my $confirm = $cgi->param('confirm');
        my $stocknumber = $cgi->param('stocknumber');
        my @barcodes = $cgi->multi_param('barcodes');
        my $items;
        if ( $stocknumber && $confirm ){
           $items = Koha::Items->search({ barcode => { -in => \@barcodes } });
           $items->update({stocknumber=>$stocknumber});
        }
        $template->param(step_3 => 1);
        $template->param(items => $items) if $items;

        print $template->output();
    }


}

1;

##FIXME for future flexibility allows use of 'Holds to pull' list
#    my $query = "
#            SELECT min(reservedate) as l_reservedate,
#            reserves.borrowernumber as borrowernumber,
#            GROUP_CONCAT(reserves.reservenotes SEPARATOR '<br/>') as notes,
#            GROUP_CONCAT(items.barcode SEPARATOR '<br/>') as barcode,
#            items.holdingbranch,
#            reserves.biblionumber,
#            reserves.branchcode as l_branch,
#            GROUP_CONCAT(DISTINCT items.itype
#                    ORDER BY items.itemnumber SEPARATOR '|') l_itype,
#            GROUP_CONCAT(DISTINCT items.location
#                    ORDER BY items.itemnumber SEPARATOR '|') l_location,
#            GROUP_CONCAT(DISTINCT items.itemcallnumber
#                    ORDER BY items.itemnumber SEPARATOR '<br/>') l_itemcallnumber,
#            GROUP_CONCAT(DISTINCT items.enumchron
#                    ORDER BY items.itemnumber SEPARATOR '<br/>') l_enumchron,
#            GROUP_CONCAT(DISTINCT items.copynumber
#                    ORDER BY items.itemnumber SEPARATOR '<br/>') l_copynumber,
#            GROUP_CONCAT(DISTINCT items.stocknumber
#                    ORDER BY items.stocknumber SEPARATOR '<br/>') l_stocknumber,
#            biblio.title,
#            biblio.author,
#            count(DISTINCT items.itemnumber) as icount,
#            count(DISTINCT reserves.borrowernumber) as rcount,
#            borrowers.firstname,
#            borrowers.surname
#    FROM reserves
#        LEFT JOIN items ON items.biblionumber=reserves.biblionumber
#        LEFT JOIN biblio ON reserves.biblionumber=biblio.biblionumber
#        LEFT JOIN branchtransfers ON items.itemnumber=branchtransfers.itemnumber
#        LEFT JOIN issues ON items.itemnumber=issues.itemnumber
#        LEFT JOIN borrowers ON reserves.borrowernumber=borrowers.borrowernumber
#    WHERE
#    reserves.found IS NULL
#    AND (reserves.itemnumber IS NULL OR reserves.itemnumber = items.itemnumber)
#    AND items.itemnumber NOT IN (SELECT itemnumber FROM branchtransfers where datearrived IS NULL)
#    AND items.itemnumber NOT IN (select itemnumber FROM reserves where found IS NOT NULL)
#    AND issues.itemnumber IS NULL
#    AND reserves.priority <> 0
#    AND reserves.suspend = 0
#    AND notforloan = 0 AND damaged = 0 AND itemlost = 0 AND withdrawn = 0
#    AND items.holdingbranch = '$branch'
#    GROUP BY reserves.biblionumber ORDER BY biblio.title
#    ";
