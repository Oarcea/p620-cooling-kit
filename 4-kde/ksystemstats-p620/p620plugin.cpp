// ksystemstats plugin for the Lenovo ThinkStation P620.
// Publishes p620/cpu/temperatureAverage: CPU Tctl (k10temp temp1) averaged over the same
// window the p620-fans controller uses (cpu_smoothing x interval from /etc/p620-fans.conf,
// default 8 x 2 s = 16 s). Read-only: it never touches the fans.
#include <QDir>
#include <QFile>
#include <QRegularExpression>
#include <QTimer>
#include <QVector>

#include <utility>

#include <KPluginFactory>

#include <systemstats/SensorContainer.h>
#include <systemstats/SensorObject.h>
#include <systemstats/SensorPlugin.h>
#include <systemstats/SensorProperty.h>

class P620Plugin : public KSysGuard::SensorPlugin
{
    Q_OBJECT
public:
    P620Plugin(QObject *parent, const QVariantList &args)
        : SensorPlugin(parent, args)
    {
        readConfig();
        findTctl();

        auto container = new KSysGuard::SensorContainer(QStringLiteral("p620"), QStringLiteral("P620"), this);
        auto cpu = new KSysGuard::SensorObject(QStringLiteral("cpu"), QStringLiteral("CPU"), container);
        const QString secs = QString::number(m_window * m_intervalMs / 1000.0);

        m_avg = new KSysGuard::SensorProperty(QStringLiteral("temperatureAverage"),
                                              QStringLiteral("CPU Temperature (%1 s average)").arg(secs), 0, cpu);
        m_avg->setShortName(QStringLiteral("CPU avg"));
        m_avg->setDescription(QStringLiteral("CPU Tctl averaged over %1 s, as seen by the p620-fans controller").arg(secs));
        m_avg->setUnit(KSysGuard::UnitCelsius);
        m_avg->setMin(0);
        m_avg->setMax(100);

        m_timer.setInterval(m_intervalMs);
        connect(&m_timer, &QTimer::timeout, this, &P620Plugin::sample);
        m_timer.start();
        sample();
    }

    QString providerName() const override
    {
        return QStringLiteral("p620");
    }

private:
    void readConfig()
    {
        QFile f(QStringLiteral("/etc/p620-fans.conf"));
        if (!f.open(QIODevice::ReadOnly | QIODevice::Text))
            return;
        bool general = false;
        static const QRegularExpression kv(QStringLiteral("^\\s*(\\w+)\\s*=\\s*([0-9.]+)"));
        while (!f.atEnd()) {
            const QString line = QString::fromUtf8(f.readLine()).trimmed();
            if (line.startsWith(QLatin1Char('[')))
                general = (line == QLatin1String("[general]"));
            if (!general)
                continue;
            const auto m = kv.match(line);
            if (!m.hasMatch())
                continue;
            bool ok = false;
            const double v = m.captured(2).toDouble(&ok);
            if (!ok || v <= 0)
                continue;
            if (m.captured(1) == QLatin1String("cpu_smoothing"))
                m_window = qMax(1, int(v));
            else if (m.captured(1) == QLatin1String("interval"))
                m_intervalMs = qMax(250, int(v * 1000));
        }
    }

    void findTctl()
    {
        const QDir hwmon(QStringLiteral("/sys/class/hwmon"));
        for (const QString &d : hwmon.entryList(QDir::Dirs | QDir::NoDotAndDotDot)) {
            QFile name(hwmon.filePath(d + QStringLiteral("/name")));
            if (name.open(QIODevice::ReadOnly) && name.readAll().trimmed() == "k10temp") {
                m_tctlPath = hwmon.filePath(d + QStringLiteral("/temp1_input"));
                return;
            }
        }
    }

    void sample()
    {
        QFile f(m_tctlPath);
        bool ok = false;
        double t = 0;
        if (!m_tctlPath.isEmpty() && f.open(QIODevice::ReadOnly))
            t = f.readAll().trimmed().toDouble(&ok) / 1000.0;
        if (!ok) {          // same as the controller: a failed read clears the history
            m_hist.clear();
            m_avg->setValue(QVariant());
            return;
        }
        m_hist.append(t);
        while (m_hist.size() > m_window)
            m_hist.removeFirst();
        double sum = 0;
        for (double v : std::as_const(m_hist))
            sum += v;
        m_avg->setValue(qRound(sum / m_hist.size() * 10) / 10.0);
    }

    KSysGuard::SensorProperty *m_avg = nullptr;
    QTimer m_timer;
    QString m_tctlPath;
    QVector<double> m_hist;
    int m_window = 8;
    int m_intervalMs = 2000;
};

K_PLUGIN_CLASS_WITH_JSON(P620Plugin, "metadata.json")

#include "p620plugin.moc"
