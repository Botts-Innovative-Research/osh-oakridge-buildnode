import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.ResultSet;
import java.sql.Statement;

public final class DuckDBNativeTempSmoke {
    private DuckDBNativeTempSmoke() {
    }

    public static void main(String[] arguments) throws Exception {
        if (arguments.length != 2) {
            throw new IllegalArgumentException("expected managed native and data temporary directories");
        }
        String actualTemp = System.getProperty("java.io.tmpdir");
        if (!arguments[0].equals(actualTemp)) {
            throw new IllegalStateException("unexpected java.io.tmpdir: " + actualTemp);
        }
        String actualDataTemp = System.getProperty("oscar.data.tmpdir");
        if (!arguments[1].equals(actualDataTemp)) {
            throw new IllegalStateException("unexpected oscar.data.tmpdir: " + actualDataTemp);
        }

        Class.forName("org.duckdb.DuckDBDriver");
        try (Connection connection = DriverManager.getConnection("jdbc:duckdb:");
             Statement statement = connection.createStatement();
             ResultSet result = statement.executeQuery("SELECT 42")) {
            if (!result.next() || result.getInt(1) != 42 || result.next()) {
                throw new IllegalStateException("DuckDB smoke query returned an unexpected result");
            }
        }
    }
}
