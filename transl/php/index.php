<?php
include_once("config.php");
include_once("lib.php");

$summary = fopen("$DATAROOT/langs/summary", "r");
$transl = array();
$sum = 0;
while ($line = fgets($summary, 1024))
{
    if (!preg_match("/LANG ([0-9a-f]+:[0-9a-f]+) ([0-9]+) ([0-9]+) ([0-9]+) ([0-9]+)/", $line, $m))
    {
        die("couldn't parse line $line");
    }

    if ($m[3] == 0)
        continue;
    
    $sum = $m[2];
    $transl[] = array('langid' => $m[1], 'name' => get_locale_name($m[1]), 'translated' => $m[3],
                      'missing' => $m[4], 'errors' => $m[5]);
}
?>
<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 4.01 Transitional//EN">
<html>
<head>
    <link rel="stylesheet" href="style.css" type="text/css"/>
    <meta http-equiv="Content-Type" content="text/html; charset=utf-8">
    <title>Wine translation statistics <?php echo $TITLE_APPENDIX ?></title>
</head>
<div class="main">
<h1>Wine translation statistics <?php echo $TITLE_APPENDIX ?></h1>

<?php echo $TITLE_DESCR ?>

<p>This page shows the state of the translations of <a href="http://www.winehq.org/">Wine</a>.
Note that some resources marked as translated may be in fact in English - sometimes developers
add new English resources into every language file. This automatic tool doesn't detect this -
it needs to be found manually by the translators. If you would like to read about how to
improve Wine translations check <?php echo $WINE_WIKI_TRANSLATIONS ?>.
</p>

<table class="index">
<tr><th></th><th>Language</th><th>Translated</th><th>Missing</th><th>Errors</th><th>&nbsp;</th></tr>
<?php
function draw_bar($tr, $err, $sum)
{
    $tr_len = floor(($tr*300)/$sum);
    $err_len = floor(($err*300)/$sum);
    if ($err_len == 0 && $err > 0)
    {
        $err_len++;
        if ($tr_len > 1)
            $tr_len--;
    }
    $miss_len = 300 - $tr_len - $err_len;
    echo '<td class="bar">';
    if ($tr_len > 0)
	echo "<img src=\"img/bar0.gif\" height=\"15\" width=\"$tr_len\" alt=\"translations\">";
    if ($err_len > 0)
	echo "<img src=\"img/bar1.gif\" height=\"15\" width=\"$err_len\" alt=\"errors\">";
//    echo "<img src=\"img/bar6.gif\" height=\"15\" width=\"$miss_len\">";
    echo "</td></tr>";
}

function nicesort($a, $b)
{
    if ($a['translated'] != $b['translated'])
        return ($a['translated'] < $b['translated']);

    // English (Unites States) always on top
    if ($a['langid'] == "009:01")
        return 0;
    if ($b['langid'] == "009:01")
        return 1;
    return strcasecmp($a['name'], $b['name']);
}

usort($transl, 'nicesort');
$nr = 1;
$missing_sum = 0;
$errors_sum = 0;
$transl_sum = 0;
$serial = 0;
for ($i = 0; $i < count($transl); $i++)
{
    extract($transl[$i]);

    echo "<tr>";
    if ($serial == 0)
    {
        for ($j = $i; $j < count($transl); $j++)
            if ($translated != $transl[$j]['translated'])
                break;
        $serial = $j - $i;
        echo "<td rowspan=\"$serial\" style=\"text-align: center\">$nr";
        echo "</td>";
    }
    echo "<td>".gen_lang_a($langid).$name."</a></td>";
    printf("<td>%d (%.1f%%)</td>", $translated, ($translated*100)/$sum);
    echo "<td>".$missing."</td><td>".$errors."</td>\n";
    draw_bar($translated, $errors, $sum);
    
    $nr++;
    $transl_sum += $translated;
    $missing_sum += $missing;
    $errors_sum += $errors;
    $serial--;
}
?>
<tr><td></td><td><b>Sum:</b></td>
<td><?php printf("%d (%.1f%%)", $transl_sum, ($transl_sum*100)/(($nr-1)*$sum)) ?></td>
<td><?php echo $missing_sum ?></td>
<td><?php echo $errors_sum ?></td>
<?php draw_bar($transl_sum, $errors_sum, ($nr-1)*$sum) ?>
</table>
</div>
<?php
if ($time = filemtime("$DATAROOT/langs/summary"))
{
    echo "<p><small>Generated on ".gmdate("j M Y, G:i:s T", $time)." (see <a href=\"runlog.php\">run log</a>)</small></p>";
}
?>
</html>
