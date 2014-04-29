$latex            = 'uplatex -shell-escape -halt-on-error';
$latex_silent     = 'uplatex -shell-escape -halt-on-error';
$bibtex           = 'pbibtex';
$dvipdf           = 'dvipdfmx -p a4 -f otf-up-ipaex.map %O -o %D %S';
$pdflatex         = 'xelatex -shell-escape -halt-on-error';
$xelatex          = 'xelatex -shell-escape -halt-on-error';
$pdf_mode         = 3;
$max_repeat       = 5;
$biber            = 'biber --bblencoding=utf8 -u -U --output_safechars';
$dvipdf           = 'dvipdfmx %O -o %D %S';
$makeindex        = 'mendex %O -o %D %S';
