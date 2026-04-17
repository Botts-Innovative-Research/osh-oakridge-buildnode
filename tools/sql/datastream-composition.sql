SELECT
    ds.id                                                             AS datastream_id,
    ds.data->>'name'                                                  AS datastream_name,
    sys.data->>'uniqueId'                                             AS system_uid,
    COUNT(o.id)                                                       AS obs_count,
    ROUND(100.0 * COUNT(o.id) / NULLIF(SUM(COUNT(o.id)) OVER (), 0), 2)
    AS pct_of_total,
    MIN(o.phenomenonTime)                                             AS first_obs,
    MAX(o.phenomenonTime)                                             AS last_obs,
    ds.max_phenomenon_time - ds.min_phenomenon_time                   AS time_span,
    pg_size_pretty(SUM(pg_column_size(o.result))::bigint)             AS approx_result_data_size
FROM datastreams ds
    LEFT JOIN obs o   ON o.dataStreamID = ds.id
    LEFT JOIN system sys ON sys.id = (ds.data->'system@id'->>'@id')::bigint
GROUP BY ds.id, ds.data, ds.min_phenomenon_time, ds.max_phenomenon_time, sys.data
ORDER BY obs_count DESC;