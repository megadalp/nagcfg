use strict;



my $ttt = "123,456 adg sdfr,sdfgh asd, fghh";
print "ДО: ========= ", $ttt, "\n";
$ttt =~ s{(?<capt_grp>[a4,]+).*?([fgh]+)}{ grp = $+{capt_grp}, }gx;
print "После: ====== ", $ttt, "\n";
print $+{capt_grp}, "\n";

__END__
my $ttt = "123,456 adg sdfr,sdfgh asd, fghh";
$ttt =~
s/(?<=,        # after a comma, but either
    (?:
        (
            (?<!\d,) #   not matching digit-comma before
            |        #   OR
            (?![\d\d]) #   not matching digit afterward
    )
  )/! !/gx;      # substitute a space

print $ttt, "\n";
