import math
import matplotlib.pyplot as plt
from matplotlib.mlab import csv2rec
from matplotlib.cbook import get_sample_data
from matplotlib.ticker import Formatter, MultipleLocator
from os.path import basename, splitext

class TagFormatter(Formatter):
    def __init__(self, tags):
        self.tags = tags

    def __call__(self, x, pos=0):
        'Return the label for time x at position pos'
        ind = int(round(x))
        if ind >= len(self.tags) or ind < 0:
            return ''
        return str(self.tags[ind])

def writeReport(outputDirectory, summary):
    html = """
        <html>
        <head>
            <style type=\"text/css\">
                h1.pass { background-color: lightgreen; }
                h1.fail { background-color: darksalmon; }
                a.pass { color: green; }
                a.fail { color: red; }
            </style>
        </head>
        <body>
            <title>Realm Core Performance</title>
            <div style="width:100%; text-align:center">
            <h1>Realm Core Performance</h1>
            <p>These graphs show the relative performance of certain operations between versions. The purpose of this report is to allow reviewers to see if there have been any unintentional performace regressions in the code being reviewed. It would be meaningless and misleading to use the numbers shown here to compare to other databases.</p>
            <br> """

    # standard deviation summary graph
    summaryGraphName = makeSummaryGraph(outputDirectory, summary)
    html += "<img align=\"middle\" id=\"summary\" src=\"" + summaryGraphName + "\"/>"

    # generate color coded link summary
    html += "<ol>"
    for title, values in summary.iteritems():
        html += "<li><a class=\"" + values['status'] + "\" href=#" + title + ">" + title + "</a></li>"
    html += "</ol><br>"

    # generate each graph section
    for title, values in summary.iteritems():
        html += "<h1 class=\"" + values['status'] + "\" id=\"" + title +"\">" + title + "</h1>"
        html += "<p>Threshold:  " + str(values['threshold']) + "</p>"
        html += "<p>Last Value: " + str(values['last_value']) + " (" + str(values['last_std']) + " standard deviations)</p>"
        html += "<img align=\"middle\" src=\"" + values['src'] + "\"/>"

    html += """
            </div>
        </body>
        </html>"""

    with open(outputDirectory + str('report.html'), 'w+') as reportFile:
        reportFile.write(html)

def getThreshold(points):
    # assumes that data has 2 or more points
    # remove the last value from computation since we are testing it
    data = points[:-1]
    mean = float(sum(data)) / max(len(data), 1)
    variance = 0
    deviations = [ math.pow(x - mean, 2) for x in data ]
    variance = sum(deviations) / max(len(deviations), 1)
    std = math.sqrt(variance)
    # we define the warninng threshold as 2 standard deviations from the mean
    threshold = mean + (2 * std)
    last_value = points[-1]
    # last_std is the distance of the last value (the one under test)
    # from the mean, in units of standard deviations
    last_std = (last_value - mean) / std
    return [threshold, last_value, last_std]

def makeSummaryGraph(outputDirectory, summary):
    summaryGraphName = "summary.png"

    ratios = {title:summary[title]['last_std'] for title in summary}

    # the y locations for the groups
    indices = range(len(ratios))
    #reversed to follow order of summary links
    indices.reverse()
    width = 1
    widths = [width/2.0] * len(ratios)

    fig, ax = plt.subplots()
    rects1 = ax.barh(indices, ratios.values(), width, color='b')

    # add some text for labels, title and axes ticks
    ax.set_xlabel('Standard Deviation')
    ax.set_title('Standard Deviations')
    ax.set_yticks(indices + widths)
    ax.set_yticklabels(ratios.keys())
    ax.set_ylim([0, len(ratios)])
    ax.set_xlim([-4, 4])
    # 2 std threshold line
    plt.axvline(x=2, color='r')

    fig.set_size_inches(10, 16)
    plt.tight_layout()
    plt.savefig(outputDirectory + summaryGraphName)
    plt.close(fig)

    return summaryGraphName

def generateReport(outputDirectory, csvFiles):
    metrics = ['min', 'max', 'med', 'avg']
    colors = {'min': '#1f77b4', 'max': '#aec7e8', 'med': '#ff7f0e', 'avg': '#ffbb78', 'threshold': '#ff1111'}

    summary = {}

    for index, fname in enumerate(csvFiles):
        bench_data = csv2rec(fname)

        print "generating graph: " + str(index) + "/" + str(len(csvFiles)) + " (" + fname + ")"
        formatter = TagFormatter(bench_data['tag'])

        fig, ax = plt.subplots()
        ax.xaxis.set_major_formatter(formatter)
        tick_spacing = 1
        ax.xaxis.set_major_locator(MultipleLocator(tick_spacing))

        plt.grid(True)
        for rank, column in enumerate(metrics):
            line, = plt.plot(bench_data[column], lw=2.5, color=colors[column])
            line.set_label(column)

        plt.legend()
        plt.xlabel('Build')
        plt.ylabel('Seconds')
        # rotate x axis labels for readability
        fig.autofmt_xdate()

        threshold, last_value, last_std = getThreshold(bench_data['avg'])
        plt.axhline(y=threshold, color=colors['threshold'])

        title = splitext(basename(fname))[0]
        plt.title(title, fontsize=18, ha='center')
        imgName = str(title) + '.png'
        plt.tight_layout()
        plt.savefig(outputDirectory + imgName)
        # refresh axis and don't store these in memory
        plt.close(fig)
        status = "fail" if last_value > threshold else "pass"
        summary[title] = {'title': title, 'src': imgName, 'threshold': threshold,
                          'last_value': last_value, 'last_std': last_std, 'status': status}

    writeReport(outputDirectory, summary)

