package io.github.hhagenbuch.agentslo;

import io.github.hhagenbuch.meter.core.attr.MeterAttributes;
import io.github.hhagenbuch.meter.spring.otel.Instruments;
import io.opentelemetry.api.common.AttributeKey;
import io.opentelemetry.api.common.Attributes;
import io.opentelemetry.exporter.otlp.metrics.OtlpGrpcMetricExporter;
import io.opentelemetry.sdk.common.CompletableResultCode;
import io.opentelemetry.sdk.metrics.InstrumentType;
import io.opentelemetry.sdk.metrics.SdkMeterProvider;
import io.opentelemetry.sdk.metrics.data.AggregationTemporality;
import io.opentelemetry.sdk.metrics.data.MetricData;
import io.opentelemetry.sdk.metrics.export.MetricExporter;
import io.opentelemetry.sdk.metrics.export.PeriodicMetricReader;
import io.opentelemetry.sdk.resources.Resource;

import java.time.Duration;
import java.util.Collection;
import java.util.HashMap;
import java.util.Map;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;

/**
 * Pushes one continuous-eval run result over OTLP using agent-meter's
 * {@link Instruments} facade, so the SLI series carry exactly the names, units,
 * and attributes the meter defines ({@code agent.sli.eval_cases},
 * {@code agent.sli.eval_pass_rate}).
 *
 * <pre>
 * java -jar slo-metrics.jar --passed 4 --total 6 --dataset sabotaged \
 *      --agent support --endpoint http://localhost:4317
 * </pre>
 */
public final class PushEvalRun {

    private static final AttributeKey<String> AGENT_NAME = AttributeKey.stringKey("agent.name");

    private PushEvalRun() {
    }

    public static void main(String[] args) throws Exception {
        Map<String, String> flags = parse(args);
        long passed = Long.parseLong(require(flags, "passed"));
        long total = Long.parseLong(require(flags, "total"));
        String endpoint = flags.getOrDefault("endpoint", "http://localhost:4317");

        // forceFlush() reports success even when the OTLP export fails, so a
        // tracking wrapper witnesses whether an export actually succeeded.
        TrackingExporter exporter = new TrackingExporter(
                OtlpGrpcMetricExporter.builder().setEndpoint(endpoint).build());
        SdkMeterProvider provider = SdkMeterProvider.builder()
                .setResource(Resource.getDefault().merge(Resource.create(
                        Attributes.of(AttributeKey.stringKey("service.name"), "agent-slo-runner"))))
                // The reader exists only because the SDK requires one to bind an
                // exporter; this process lives ~2s, so the interval never fires —
                // forceFlush() below is the actual send.
                .registerMetricReader(PeriodicMetricReader.builder(exporter)
                        .setInterval(Duration.ofDays(1))
                        .build())
                .build();
        try {
            Instruments instruments = new Instruments(provider.get("agent-meter"));
            Attributes dims = Attributes.builder()
                    .put(MeterAttributes.SLI_DATASET, flags.getOrDefault("dataset", "unknown"))
                    .put(MeterAttributes.FEATURE, "slo-measurement")
                    .put(AGENT_NAME, flags.getOrDefault("agent", "unknown"))
                    .build();
            instruments.recordEvalRun(passed, total, dims);
        } finally {
            // The periodic reader has not ticked yet — flush is the actual send.
            provider.forceFlush().join(10, TimeUnit.SECONDS);
            provider.shutdown().join(10, TimeUnit.SECONDS);
        }
        if (!exporter.succeeded()) {
            System.err.println("metric export failed (collector unreachable at " + endpoint + ")");
            System.exit(1);
        }
        System.out.printf("pushed eval run %d/%d to %s%n", passed, total, endpoint);
    }

    /** Delegates to the OTLP exporter and remembers whether any export succeeded. */
    private static final class TrackingExporter implements MetricExporter {
        private final MetricExporter delegate;
        private final AtomicBoolean succeeded = new AtomicBoolean(false);

        private TrackingExporter(MetricExporter delegate) {
            this.delegate = delegate;
        }

        boolean succeeded() {
            return succeeded.get();
        }

        @Override
        public CompletableResultCode export(Collection<MetricData> metrics) {
            CompletableResultCode result = delegate.export(metrics);
            result.whenComplete(() -> {
                if (result.isSuccess()) {
                    succeeded.set(true);
                }
            });
            return result;
        }

        @Override
        public CompletableResultCode flush() {
            return delegate.flush();
        }

        @Override
        public CompletableResultCode shutdown() {
            return delegate.shutdown();
        }

        @Override
        public AggregationTemporality getAggregationTemporality(InstrumentType instrumentType) {
            return delegate.getAggregationTemporality(instrumentType);
        }
    }

    private static Map<String, String> parse(String[] args) {
        Map<String, String> flags = new HashMap<>();
        for (int i = 0; i + 1 < args.length; i += 2) {
            if (!args[i].startsWith("--")) {
                throw new IllegalArgumentException("expected --flag value pairs, got: " + args[i]);
            }
            flags.put(args[i].substring(2), args[i + 1]);
        }
        return flags;
    }

    private static String require(Map<String, String> flags, String key) {
        String value = flags.get(key);
        if (value == null) {
            throw new IllegalArgumentException("--" + key + " is required");
        }
        return value;
    }
}
