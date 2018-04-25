#!perl
# PODNAME: files-to-elasticsearch.pl
# ABSTRACT: A simple utility to tail a file and index each line as a document in ElasticSearch
use strict;
use warnings;

use Getopt::Long::Descriptive qw(describe_options);
use Hash::Merge::Simple qw(merge);
use JSON::MaybeXS qw(decode_json encode_json);
use Log::Log4perl qw(:easy);
use Module::Load qw(load);
use Module::Loaded qw(is_loaded);
use Ref::Util qw(is_arrayref is_hashref);
use YAML ();

sub POE::Kernel::ASSERT_DEFAULT { 1 }
use POE qw(
    Component::ElasticSearch::Indexer
    Wheel::FollowTail
);

my %DEFAULT = (
    config => '/etc/file-to-elasticsearch.yaml',
    stats_interval => 60,
);

my ($opt,$usage) = describe_options('%c %o',
    ['config|c:s', "Config file, default: $DEFAULT{config}",
        { default => $DEFAULT{config}, callbacks => { "must be a readable file" => sub { -r $_[0] } } }
    ],
    ['log4perl-config|L:s', "Log4perl Configuration to use, defaults to STDERR",
        { callbacks => { "must be a readable file" => sub { -r $_[0] } } }
    ],
    ['stats-interval|s:i', "Seconds between displaying statistics, default: $DEFAULT{stats_interval}",
        { default => $DEFAULT{stats_interval} },
    ],
    ['debug',       "Enable most verbose output" ],
    [],
    ['help', "Display this help.", { shortcircuit => 1 }],
);

if( $opt->help ) {
    print $usage->text;
    exit 0;
}

my $config = YAML::LoadFile( $opt->config );

# Initialize Logging
my $level = $opt->debug ? 'TRACE' : 'DEBUG';
my $loggingConfig = $opt->log4perl_config || \qq{
    log4perl.logger = $level, Screen
    log4perl.appender.Screen = Log::Log4perl::Appender::ScreenColoredLevels
    log4perl.appender.Screen.layout   = PatternLayout
    log4perl.appender.Screen.layout.ConversionPattern = %d [%P] %p - %m%n
};
Log::Log4perl->init($loggingConfig);

my $main = POE::Session->create(
    inline_states => {
       _start => \&main_start,
       _stop  => \&main_stop,
       _child => \&main_child,
       stats  => \&main_stats,

       got_new_line     => \&got_new_line,
       get_error        => \&got_error,
       log4perl_refresh => \&log4perl_refresh,
    },
    heap => {
        config => $config,
        stats  => {},
    },
);

POE::Kernel->run();
exit 0;

sub main_start {
    my ($kernel,$heap) = @_[KERNEL,HEAP];

    my $config = $heap->{config};
    my %defaults = (
        interval => 5,
        index    => 'files-%Y.%m.%d',
        type     => 'log',
    );

    my $files = 0;
    foreach my $tail ( @{ $config->{tail} } ) {
        if( -r $tail->{file} ) {
            my $wheel = POE::Wheel::FollowTail->new(
                Filename     => $tail->{file},
                InputEvent   => 'got_new_line',
                ErrorEvent   => 'got_error',
                PollInterval => $tail->{interval} || $defaults{interval},
            );
            $heap->{wheels}{$wheel->ID} = $wheel;
            $heap->{instructions}{$wheel->ID} = {
                %defaults,
                %{ $tail },
            };
            $files++;
            DEBUG(sprintf "Wheel %d tailing %s", $wheel->ID, $tail->{file});
        }
    }

    die sprintf("No files found to tail in %s", $opt->config) unless $files > 0;

    my $es = $config->{elasticsearch} || {};
    $heap->{elasticsearch} = POE::Component::ElasticSearch::Indexer->spawn(
        Alias         => 'es',
        Servers       => $es->{servers} || [qw( localhost:9200 )],
        Timeout       => $es->{timeout} || 5,
        FlushInterval => $es->{flush_interval} || 10,
        FlushSize     => $es->{flush_size} || 100,
        LoggingConfig => $loggingConfig,
        StatsInterval => $opt->stats_interval,
        StatsHandler  => sub {
            my ($stats) = @_;
            foreach my $k (keys %{ $stats }) {
                $heap->{stats}{$k} ||= 0;
                $heap->{stats}{$k}++;
            }
        },
        exists $es->{index} ? ( DefaultIndex => $es->{index} ) : (),
        exists $es->{type}  ? ( DefaultType  => $es->{type}  ) : (),
    );

    # Watch the Log4perl Config
    $kernel->delay( log4perl_refresh => 60 ) if $opt->log4perl_config;
    $kernel->delay( stats => $opt->stats_interval );

    INFO("Started $0 watching $files files.");
}

sub main_stop {
    $poe_kernel->post( es => 'shutdown' );
    FATAL("Shutting down $0");
}

sub main_child {
    my ($kernel,$heap,$reason,$child) = @_[KERNEL,HEAP,ARG0,ARG1];
    INFO(sprintf "Child [%d] %s event.", $child->ID, $reason);
}

sub main_stats {
    my ($kernel,$heap) = @_[KERNEL,HEAP];

    # Reschedule
    $kernel->delay( stats => $opt->stats_interval );

    # Collect our stats
    my $stats = delete $heap->{stats};
    $heap->{stats} = {};

    # Display them
    my $message = keys %{ $stats } ? join(", ", map {"$_=$stats->{$_}"} sort keys %{ $stats })
                : "Nothing to report.";
    INFO("STATS - $message");
}

sub got_error {
    my ($kernel,$heap,$op,$errnum,$errstr,$wheel_id) = @_[KERNEL,HEAP,ARG0..ARG3];

    ERROR("Wheel $wheel_id during $op got $errnum : $errstr");

    # Remove the Wheel from the polling
    if( exists $heap->{wheels}{$wheel_id} ) {
        delete $heap->{wheels}{$wheel_id};
        $heap->{stats}{wheel_error} ||= 0;
        $heap->{stats}{wheel_error}++;
    }

    # Close the ElasticSearch session if this is the last wheel
    if( !keys %{ $heap->{wheels} } ) {
        $kernel->post( es => 'shutdown' );
    }
}

sub log4perl_refresh {
    my $kernel = $_[KERNEL];
    TRACE("Rescanning Log4perl configuration at" . $opt->log4perl_config);
    # Reschedule
    $kernel->delay( log4perl_refresh => 60 );
    # Rescan the Log4perl configuration
    Log::Log4perl::Config->watcher->force_next_check();
    return;
}

sub got_new_line {
    my ($kernel,$heap,$line,$wheel_id) = @_[KERNEL,HEAP,ARG0,ARG1];

    $heap->{stats}{received} ||= 0;
    $heap->{stats}{received}++;

    my $instr = $heap->{instructions}{$wheel_id};

    my $doc;
    if( $instr->{decode} ) {
        my $decoders = is_arrayref($instr->{decode}) ? $instr->{decode} : [ $instr->{decode} ];
        foreach my $decoder ( @{ $decoders } ) {
            if( $decoder eq 'json' ) {
                my $start = index('{', $line);
                my $blob  = $start > 0 ? substr($line,$start) : $line;
                my $new;
                eval {
                    $new = decode_json($blob);
                    1;
                } or do {
                    my $err = $@;
                    TRACE("Bad JSON, error: $err\n$blob");
                    next;
                };
                $doc = merge( $doc, $new );
            }
            elsif( $decoder eq 'syslog' ) {
                unless( is_loaded('Parse::Syslog::Line') ) {
                    eval {
                        load "Parse::Syslog::Line";
                        1;
                    } or do {
                        my $err = $@;
                        die "To use the 'syslog' decoder, please install Parse::Syslog::Line: $err";
                    };
                    no warnings qw(once);
                    $Parse::Syslog::Line::PruneRaw = 1;
                }
                # If we make it here, we're ready to parse
                $doc = Parse::Syslog::Line::parse_syslog_line($line);
            }
        }
    }

    # Extractors
    if( my $extracters = $instr->{extract} ) {
        foreach my $extract( @{ $extracters } ) {
            # Only process items with a "by"
            if( $extract->{by} ) {
                my $from = $extract->{from} ? ( is_hashref($doc) && exists $doc->{$extract->{from}} ? $doc->{$extract->{from}} : undef )
                         : $line;
                next unless $from;
                if( $extract->{when} ) {
                    next unless $from =~ /$extract->{when}/;
                }
                if( $extract->{by} eq 'split' ) {
                    next unless $extract->{split_on};
                    my @parts = split /$extract->{split_on}/, $from;
                    if( my $keys = $extract->{split_parts} ) {
                        # Name parts
                        for( my $i = 0; $i < @parts; $i++ ) {
                            next unless $keys->[$i] and length $keys->[$i] and $parts[$i];
                            next if lc $keys->[$i] eq 'null' or lc $keys->[$i] eq 'undef';
                            if( my $into = $extract->{into} ) {
                                # Make sure we have a hash reference
                                $doc ||=  {};
                                $doc->{$into} = {} unless is_hashref($doc->{$into});
                                $doc->{$into}{$keys->[$i]} = $parts[$i];
                            }
                            else {
                                $doc ||=  {};
                                $doc->{$keys->[$i]} = $parts[$i];
                            }
                        }
                    }
                    else {
                        # This is an array, so it's simple
                        my $target = $extract->{into} ? $extract->{into} : $extract->{from};
                        $doc->{$target} = @parts > 1  ? [ grep { defined and length } @parts ] : $parts[0];
                    }
                }
                elsif( $extract->{by} eq 'regex' ) {
                    # TODO: Regex Decoder
                }
            }
        }
    }

    # Skip if the document isn't put together yet
    return unless $doc;

    $heap->{stats}{docs} ||= 0;
    $heap->{stats}{docs}++;

    # Store Line in _raw now
    $doc->{_raw}  = $line;
    $doc->{_path} = $instr->{file};

    # Mutators
    if( my $mutate = $instr->{mutate} ) {
        # Copy
        if( my $copy = $mutate->{copy} ) {
            foreach my $k ( keys %{ $copy } ) {
                my $destinations = is_arrayref($copy->{$k}) ? $copy->{$k} : [ $copy->{$k} ];
                foreach my $dst ( @{ $destinations } ) {
                    $doc->{$dst} = $doc->{$k};
                }
            }
        }
        # Rename Keys
        if( my $rename = $mutate->{rename} ) {
            foreach my $k ( keys %{ $rename } ) {
                next unless exists $doc->{$k};
                $doc->{$rename->{$k}} = delete $doc->{$k};
            }
        }
        # Remove unwanted keys
        if( $mutate->{remove} ) {
            foreach my $k ( @{ $mutate->{remove} } ) {
                delete $doc->{$k} if exists $doc->{$k};
            }
        }
        # Append
        if( my $append = $mutate->{append} ) {
            foreach my $k ( keys %{ $append } ) {
                $doc ||=  {};
                $doc->{$k} = $append->{$k};
            }
        }
        # Prune empty or undefined keys
        if( $mutate->{prune} ) {
            foreach my $k (keys %{ $doc }) {
                delete $doc->{$k} unless defined $doc->{$k} and length $doc->{$k};
            }
        }
    }

    foreach my $meta (qw(index type)) {
        $doc->{"_$meta"} = $instr->{$meta} if exists $instr->{$meta};
    }

    if( $opt->debug ) {
        TRACE("Indexing: " . encode_json($doc));
    }

    # Send the document to ElasticSearch
    $kernel->post( es => queue => $doc );
}
