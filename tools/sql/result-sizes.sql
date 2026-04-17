SELECT
    ds.id                                           AS datastream_id,
    ds.data->>'name'                                AS datastream_name,
    COUNT(o.id)                                     AS obs_count,
    pg_size_pretty(AVG(pg_column_size(o.result))::bigint)
    AS avg_result_size,
    pg_size_pretty(MAX(pg_column_size(o.result))::bigint)
    AS max_result_size,
    pg_size_pretty(SUM(pg_column_size(o.result))::bigint)
    AS total_result_size
FROM obs_datastreams ds
    JOIN obs o ON o.dataStreamID = ds.id
GROUP BY ds.id, ds.data
ORDER BY SUM(pg_column_size(o.result)) DESC;